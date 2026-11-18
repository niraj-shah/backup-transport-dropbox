#!/usr/local/cpanel/3rdparty/bin/perl

# backup_transport_dropbox.pl
#
# Custom cPanel Backup Transport for Dropbox
# Compatible with AlmaLinux 8 / 9, cPanel & WHM, and modern Dropbox OAuth2
#
# Copyright 2019, cPanel, L.L.C.
# All rights reserved
# copyright@cpanel.net
# https://cpanel.net
#
# Modifications Copyright (c) 2026 Niraj Shah
# Modified to support AlmaLinux, modern cPanel versions, and OAuth2 Refresh Tokens.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

BEGIN {
    # Determine the current running Perl major/minor version (e.g. 5.42 or 542)
    my $ver_str = sprintf("%vd", $^V);
    my ($maj, $min) = ($ver_str =~ /^(\d+)\.(\d+)/);
    my $ver_num     = defined $maj && defined $min ? "$maj.$min" : '';
    my $ver_compact = defined $maj && defined $min ? "$maj$min"   : '';

    # Candidate fallback paths for CPAN modules on AlmaLinux and cPanel
    # Note: We only match the current Perl version and NEVER wildcard '*' across different versions,
    # and we PUSH to @INC (append) so native version-matched XS modules (IO, Socket, etc.) take precedence.
    my @fallback_dirs = (
        '/usr/local/share/perl5',
        '/usr/local/lib64/perl5',
        '/usr/share/perl5',
        '/usr/share/perl5/vendor_perl',
        '/usr/lib64/perl5/vendor_perl',
    );

    if ($ver_num ne '') {
        push @fallback_dirs, (
            "/usr/local/share/perl5/$ver_num",
            "/usr/local/lib64/perl5/$ver_num",
        );
    }

    if ($ver_compact ne '') {
        push @fallback_dirs, (
            "/usr/local/cpanel/3rdparty/perl/$ver_compact/lib/perl5/cpanel_lib",
            "/usr/local/cpanel/3rdparty/perl/$ver_compact/lib64/perl5/cpanel_lib",
            "/opt/cpanel/perl5/$ver_compact/lib/perl5",
        );
    }

    # Append to the end of @INC to prevent Perl binary API mismatch (e.g., IO.c v5.40 vs v5.42)
    for my $dir (@fallback_dirs) {
        if ( defined $dir && -d $dir && !grep { $_ eq $dir } @INC ) {
            push @INC, $dir;
        }
    }
}

use strict;
use warnings;
use IO::File;
use File::Spec;
use JSON::PP ();
use LWP::UserAgent;

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
# You can define credentials here OR save them in /etc/cpanel_dropbox.json:
# {
#   "app_key": "YOUR_APP_KEY",
#   "app_secret": "YOUR_APP_SECRET",
#   "refresh_token": "YOUR_REFRESH_TOKEN"
# }

our $VERSION = '2.1.0';

our $APP_KEY       = 'APP_KEY';
our $APP_SECRET    = 'APP_SECRET';
our $REFRESH_TOKEN = 'MY_REFRESH_TOKEN'; # Long-lived refresh token
our $ACCESS_TOKEN  = '';                 # Optional legacy static token (expires in 4 hrs if newly generated)

# Chunk size for multipart upload: 16 MB is reliable and prevents cPanel timeouts on large backups (>2GB)
our $CHUNK_SIZE = 16 * 1024 * 1024;
our $| = 1; # Disable STDOUT buffering for real-time progress to cPanel transporter

# External config paths to check
my @config_paths = (
    '/etc/cpanel_dropbox.json',
    '/etc/cpanel/backup-transport-dropbox.json',
);

# Load JSON config if present
for my $cfg_file (@config_paths) {
    if ( -f $cfg_file && -r $cfg_file ) {
        if ( open my $fh, '<', $cfg_file ) {
            my $raw = do { local $/; <$fh> };
            close $fh;
            my $data = eval { JSON::PP::decode_json($raw) };
            if ( $data && ref $data eq 'HASH' ) {
                $APP_KEY       = $data->{app_key}       if defined $data->{app_key};
                $APP_SECRET    = $data->{app_secret}    if defined $data->{app_secret};
                $REFRESH_TOKEN = $data->{refresh_token} if defined $data->{refresh_token};
                $ACCESS_TOKEN  = $data->{access_token}  if defined $data->{access_token};
                last;
            }
        }
    }
}

# ------------------------------------------------------------------------------
# Interactive Setup CLI Mode (--setup)
# ------------------------------------------------------------------------------
if ( @ARGV && ( $ARGV[0] eq '--setup' || $ARGV[0] eq '--token' ) ) {
    run_setup();
    exit 0;
}

# ------------------------------------------------------------------------------
# Command Routing
# ------------------------------------------------------------------------------
my %commands = (
    put    => \&my_put,
    get    => \&my_get,
    ls     => \&my_ls,
    mkdir  => \&my_mkdir,
    chdir  => \&my_chdir,
    rmdir  => \&my_rmdir,
    delete => \&my_delete,
);

usage() if ( @ARGV < 2 );

my ( $cmd, $local_dir, @args ) = @ARGV;
usage() unless exists $commands{$cmd};

# Initialize Dropbox client with automatic token refreshing
my $dropbox = init_dropbox();

# Execute the cPanel command
$commands{$cmd}->(@args);

exit 0;

# ------------------------------------------------------------------------------
# Dropbox Initialization & OAuth2 Refresh Token Management
# ------------------------------------------------------------------------------
sub init_dropbox {
    eval {
        require WebService::Dropbox;
        WebService::Dropbox->import();
        1;
    } or do {
        print STDERR "ERROR: Cannot locate WebService::Dropbox module: $@\n";
        print STDERR "On AlmaLinux / cPanel, install it by running:\n";
        print STDERR "  /usr/local/cpanel/3rdparty/bin/perl -MCPAN -e 'install WebService::Dropbox'\n";
        print STDERR "  or: dnf install -y perl-CPAN gcc openssl-devel && cpan WebService::Dropbox\n";
        exit 1;
    };

    my $dbx = WebService::Dropbox->new(
        {
            key    => $APP_KEY,
            secret => $APP_SECRET,
        }
    );

    # If we have a refresh token, obtain or refresh the access token
    if ( defined $REFRESH_TOKEN && $REFRESH_TOKEN ne '' && $REFRESH_TOKEN ne 'MY_REFRESH_TOKEN' ) {
        my $token = get_valid_access_token($APP_KEY, $APP_SECRET, $REFRESH_TOKEN);
        if ($token) {
            $dbx->access_token($token);
            return $dbx;
        } else {
            print STDERR "ERROR: Failed to refresh Dropbox access token using refresh_token.\n";
            exit 1;
        }
    }
    # Fallback to static access token
    elsif ( defined $ACCESS_TOKEN && $ACCESS_TOKEN ne '' && $ACCESS_TOKEN ne 'MY_ACCESS_TOKEN' ) {
        $dbx->access_token($ACCESS_TOKEN);
        return $dbx;
    }
    else {
        print STDERR "ERROR: No valid Dropbox credentials configured in backup_transport_dropbox.pl or /etc/cpanel_dropbox.json.\n";
        print STDERR "Run: /usr/local/cpanel/3rdparty/bin/perl $0 --setup\n";
        exit 1;
    }
}

# Retrieve cached token or request a fresh one from Dropbox API
sub get_valid_access_token {
    my ( $key, $secret, $refresh ) = @_;

    # Cache token per key in /tmp with safe permissions
    my $cache_hash = substr( unpack( "H*", $key ), 0, 12 );
    my $cache_file = "/tmp/.cpanel_dropbox_tok_${cache_hash}.json";

    # Check cache (valid if > 300 seconds left before expiration)
    if ( -f $cache_file ) {
        if ( open my $fh, '<', $cache_file ) {
            my $content = do { local $/; <$fh> };
            close $fh;
            my $cdata = eval { JSON::PP::decode_json($content) };
            if ( $cdata && $cdata->{access_token} && $cdata->{expires_at} ) {
                if ( $cdata->{expires_at} > ( time() + 300 ) ) {
                    return $cdata->{access_token};
                }
            }
        }
    }

    # Request new access token from Dropbox OAuth2 endpoint
    my $ua = LWP::UserAgent->new( timeout => 30 );
    my $res = $ua->post(
        'https://api.dropboxapi.com/oauth2/token',
        [
            grant_type    => 'refresh_token',
            refresh_token => $refresh,
            client_id     => $key,
            client_secret => $secret,
        ]
    );

    if ( $res->is_success ) {
        my $data = eval { JSON::PP::decode_json( $res->decoded_content ) };
        if ( $data && $data->{access_token} ) {
            my $new_token = $data->{access_token};
            my $expires_in = $data->{expires_in} || 14400;

            # Write cache
            if ( open my $cfh, '>', $cache_file ) {
                chmod 0600, $cache_file;
                print $cfh JSON::PP::encode_json(
                    {
                        access_token => $new_token,
                        expires_at   => time() + $expires_in,
                    }
                );
                close $cfh;
            }
            return $new_token;
        }
    }

    print STDERR "Dropbox Token Refresh Error: " . $res->status_line . " - " . $res->decoded_content . "\n";
    return undef;
}

# ------------------------------------------------------------------------------
# Path Normalization (Dropbox API v2 Compliant)
# - Root is empty string ""
# - Folders/files start with single "/" and have no trailing slash
# ------------------------------------------------------------------------------
sub convert_path {
    my ($path) = @_;
    return '' unless defined $path;

    # Trim whitespace
    $path =~ s/^\s+|\s+$//g;

    # If relative path and local_dir is provided and not root
    if ( $path !~ m|^/| && defined $local_dir && $local_dir ne '' && $local_dir ne '/' ) {
        my $prefix = $local_dir;
        $prefix =~ s|/+$||;
        $path = $prefix . '/' . $path;
    }

    # Clean consecutive slashes
    $path =~ s|/{2,}|/|g;

    # Remove trailing slashes
    $path =~ s|/+$||;

    # Root becomes empty string
    return '' if $path eq '' || $path eq '/';

    # Ensure single leading slash
    $path = '/' . $path unless $path =~ m|^/|;

    return $path;
}

# ------------------------------------------------------------------------------
# cPanel Custom Destination Command Implementations
# ------------------------------------------------------------------------------

#
# Copy a local file to remote destination
#
sub my_put {
    my ( $local, $remote, $host, $user, $password ) = @_;

    $remote = convert_path($remote);
    my $size = -s $local;
    unless ( defined $size ) {
        print STDERR "ERROR: Local file does not exist: $local\n";
        exit 1;
    }

    if ( $size > $CHUNK_SIZE ) {
        _upload_multipart( $local, $remote, $size );
    }
    else {
        _upload_single( $local, $remote );
    }
    return;
}

sub _upload_single {
    my ( $local, $remote ) = @_;

    my $fh = IO::File->new( $local, 'r' );
    unless ($fh) {
        print STDERR "ERROR: Could not open $local: $!\n";
        exit 1;
    }
    binmode($fh);

    my $res = $dropbox->upload( $remote, $fh, { mode => 'overwrite' } );
    $fh->close;

    if ( $dropbox->error || !$res ) {
        my $err = $dropbox->error || 'Unknown upload error';
        print STDERR "ERROR: Dropbox single upload failed for '$remote': $err\n";
        exit 1;
    }
    return 1;
}

sub _upload_multipart {
    my ( $local, $remote, $size ) = @_;

    open( my $fh, '<', $local ) or do {
        print STDERR "ERROR: Could not open $local for reading: $!\n";
        exit 1;
    };
    binmode($fh);

    my $buf;
    my $session_id;
    my $offset = 0;

    while ( my $read = read( $fh, $buf, $CHUNK_SIZE ) ) {
        if ( !defined $session_id ) {
            # Start session with first chunk
            my $res = $dropbox->upload_session_start($buf);
            if ( $res && $res->{session_id} ) {
                $session_id = $res->{session_id};
                $offset += $read;
                print STDOUT '.';
            } else {
                my $err = $dropbox->error || 'Failed to start session';
                close $fh;
                print STDERR "ERROR: Dropbox upload_session_start failed: $err\n";
                exit 1;
            }
        }
        else {
            # Subsequent chunks
            if ( eof($fh) ) {
                # Last chunk - finish session
                my $res = _session_finish_with_retry( $session_id, $offset, $buf, $remote );
                close $fh;
                if ($res) {
                    print STDOUT "\n";
                    return 1;
                } else {
                    my $err = $dropbox->error || 'Failed to finish session';
                    print STDERR "ERROR: Dropbox upload_session_finish failed: $err\n";
                    exit 1;
                }
            } else {
                # Intermediate chunk - append with retry
                my $ok = _session_append_with_retry( $session_id, $offset, $buf );
                if ($ok) {
                    $offset += $read;
                    print STDOUT '.';
                } else {
                    my $err = $dropbox->error || 'Failed to append chunk';
                    close $fh;
                    print STDERR "ERROR: Dropbox upload_session_append failed at offset $offset: $err\n";
                    exit 1;
                }
            }
        }
    }
    close $fh;

    # Handle edge case where file was exact multiple of chunk size
    if ( defined $session_id ) {
        my $res = _session_finish_with_retry( $session_id, $offset, '', $remote );
        unless ($res) {
            my $err = $dropbox->error || 'Failed to finish session';
            print STDERR "ERROR: Dropbox upload_session_finish failed: $err\n";
            exit 1;
        }
        print STDOUT "\n";
    }

    return 1;
}

sub _session_append_with_retry {
    my ( $session_id, $offset, $data ) = @_;
    my $retries = 3;

    while ( $retries-- > 0 ) {
        my $res = $dropbox->upload_session_append_v2(
            $data,
            {
                cursor => {
                    session_id => $session_id,
                    offset     => $offset,
                },
                close => JSON::PP::false,
            }
        );
        return 1 if ( $res || !$dropbox->error );
        sleep 2;
    }
    return 0;
}

sub _session_finish_with_retry {
    my ( $session_id, $offset, $data, $remote ) = @_;
    my $retries = 3;

    while ( $retries-- > 0 ) {
        my $res = $dropbox->upload_session_finish(
            $data,
            {
                cursor => {
                    session_id => $session_id,
                    offset     => $offset,
                },
                commit => {
                    path       => $remote,
                    mode       => 'overwrite',
                    autorename => JSON::PP::false,
                    mute       => JSON::PP::false,
                }
            }
        );
        return 1 if ( $res && !$dropbox->error );
        sleep 2;
    }
    return 0;
}

#
# Copy a remote file to local destination
#
sub my_get {
    my ( $remote, $local, $host, $user, $password ) = @_;

    $remote = convert_path($remote);
    my $fh = IO::File->new( $local, '>' );
    unless ($fh) {
        print STDERR "ERROR: Could not open local file '$local' for writing: $!\n";
        exit 1;
    }
    binmode($fh);

    $dropbox->download( $remote, $fh );
    $fh->close;

    if ( $dropbox->error ) {
        print STDERR "ERROR: Dropbox download failed for '$remote': " . $dropbox->error . "\n";
        exit 1;
    }
    return;
}

#
# List directory contents in 'ls -l' format expected by cPanel
#
sub my_ls {
    my ( $path, $host, $user, $password ) = @_;

    $path = convert_path($path);
    my %contents;

    my $result = $dropbox->list_folder($path);

    if ( $dropbox->error ) {
        my $err = $dropbox->error;
        # If directory does not exist, return empty output cleanly
        if ( $err =~ /path\/not_found/i ) {
            return;
        }
        print STDERR "ERROR: Dropbox list_folder failed for '$path': $err\n";
        exit 1;
    }

    while ($result) {
        for my $entry ( @{ $result->{'entries'} || [] } ) {
            my $name = $entry->{'name'};
            my $type = ( defined $entry->{'.tag'} && $entry->{'.tag'} eq 'folder' ) ? 'd' : '-';
            my $size = $entry->{'size'} || 0;

            $contents{$name} = {
                type => $type,
                size => $size,
            };
        }

        last unless $result->{'has_more'};
        $result = $dropbox->list_folder_continue( $result->{'cursor'} );
    }

    # Format output to match standard 'ls -l' required by cPanel backup parser
    for my $name ( sort keys %contents ) {
        my $type = $contents{$name}{type};
        my $size = $contents{$name}{size};
        print "${type}rw-r--r-- 1 root root ${size} Jan 01 00:00 ${name}\n";
    }

    return;
}

#
# Create a remote directory
#
sub my_mkdir {
    my ( $path, $recurse, $host, $user, $password ) = @_;

    $path = convert_path($path);
    return if $path eq ''; # Root folder already exists

    $dropbox->create_folder($path);

    if ( $dropbox->error ) {
        my $err = $dropbox->error;
        # Safe handling: if folder already exists (path/conflict), ignore error
        if ( $err =~ /path\/conflict/i ) {
            return;
        }
        print STDERR "ERROR: Dropbox create_folder failed for '$path': $err\n";
        exit 1;
    }
    return;
}

#
# Change directory
# Prints the normalized remote directory path to STDOUT
#
sub my_chdir {
    my ( $path, $host, $user, $password ) = @_;

    print convert_path($path) . "\n";
    return;
}

#
# Recursively delete a directory on remote destination
#
sub my_rmdir {
    my ( $path, $host, $user, $password ) = @_;

    $path = convert_path($path);
    return if $path eq ''; # Never delete root folder

    $dropbox->delete($path);

    if ( $dropbox->error ) {
        my $err = $dropbox->error;
        # If already deleted, treat as success (idempotent)
        return if $err =~ /path_lookup\/not_found/i;
        print STDERR "ERROR: Dropbox rmdir failed for '$path': $err\n";
        exit 1;
    }
    return;
}

#
# Delete an individual remote file
#
sub my_delete {
    my ( $path, $host, $user, $password ) = @_;

    $path = convert_path($path);
    return if $path eq '';

    $dropbox->delete($path);

    if ( $dropbox->error ) {
        my $err = $dropbox->error;
        # If already deleted, treat as success (idempotent)
        return if $err =~ /path_lookup\/not_found/i;
        print STDERR "ERROR: Dropbox delete failed for '$path': $err\n";
        exit 1;
    }
    return;
}

# ------------------------------------------------------------------------------
# Usage & Setup Helper
# ------------------------------------------------------------------------------
sub usage {
    my @cmds = sort keys %commands;
    print STDERR "cPanel Custom Backup Transport for Dropbox (v$VERSION)\n";
    print STDERR "Usage: $0 cmd local_dir [cmd_args...]\n";
    print STDERR "Supported commands: @cmds\n\n";
    print STDERR "To configure Dropbox OAuth2 credentials interactively, run:\n";
    print STDERR "  $0 --setup\n";
    exit 1;
}

sub run_setup {
    print "==========================================================\n";
    print " Dropbox OAuth2 Setup for cPanel Backup Transport         \n";
    print "==========================================================\n\n";

    my $key    = ( $APP_KEY ne 'MY_APP_KEY' )       ? $APP_KEY    : '';
    my $secret = ( $APP_SECRET ne 'MY_APP_SECRET' ) ? $APP_SECRET : '';

    if ( !$key ) {
        print "Enter your Dropbox App Key: ";
        $key = <STDIN>;
        $key = '' unless defined $key;
        chomp($key);
        $key =~ s/^\s+|\s+$//g;
    } else {
        print "Using App Key: $key\n";
    }

    if ( !$secret ) {
        print "Enter your Dropbox App Secret: ";
        $secret = <STDIN>;
        $secret = '' unless defined $secret;
        chomp($secret);
        $secret =~ s/^\s+|\s+$//g;
    } else {
        print "Using App Secret: [Configured]\n";
    }

    if ( !$key || !$secret ) {
        print STDERR "ERROR: Both App Key and App Secret are required.\n";
        exit 1;
    }

    my $auth_url = "https://www.dropbox.com/oauth2/authorize?client_id=${key}&response_type=code&token_access_type=offline";

    print "\n1. Open this URL in your browser:\n\n";
    print "   $auth_url\n\n";
    print "2. Authorize the app and copy the Authorization Code.\n";
    print "Enter Authorization Code: ";
    my $code = <STDIN>;
    $code = '' unless defined $code;
    chomp($code);
    $code =~ s/^\s+|\s+$//g;

    unless ($code) {
        print STDERR "ERROR: Authorization code cannot be empty.\n";
        exit 1;
    }

    print "\nExchanging authorization code for permanent Refresh Token...\n";

    my $ua  = LWP::UserAgent->new( timeout => 30 );
    my $res = $ua->post(
        'https://api.dropboxapi.com/oauth2/token',
        [
            code          => $code,
            grant_type    => 'authorization_code',
            client_id     => $key,
            client_secret => $secret,
        ]
    );

    if ( $res->is_success ) {
        my $data = eval { JSON::PP::decode_json( $res->decoded_content ) };
        if ( $data && $data->{refresh_token} ) {
            my $r_token = $data->{refresh_token};
            print "\nSUCCESS! Your permanent Refresh Token is:\n";
            print "----------------------------------------------------------\n";
            print "$r_token\n";
            print "----------------------------------------------------------\n\n";

            print "Would you like to save this configuration to /etc/cpanel_dropbox.json? (y/n): ";
            chomp( my $ans = <STDIN> );
            if ( lc($ans) eq 'y' ) {
                my $cfg = {
                    app_key       => $key,
                    app_secret    => $secret,
                    refresh_token => $r_token,
                };
                my $cfg_path = '/etc/cpanel_dropbox.json';
                if ( open my $cfh, '>', $cfg_path ) {
                    chmod 0600, $cfg_path;
                    print $cfh JSON::PP->new->pretty->encode($cfg);
                    close $cfh;
                    print "Configuration successfully saved to $cfg_path with 0600 permissions.\n";
                } else {
                    print STDERR "Could not write to $cfg_path: $!\nYou can manually update $0 with your credentials.\n";
                }
            }
            return;
        }
    }

    print STDERR "Failed to obtain refresh token: " . $res->status_line . "\n";
    print STDERR $res->decoded_content . "\n";
    exit 1;
}
