# cPanel Custom Backup Transport for Dropbox (AlmaLinux & modern cPanel)

An updated, production-ready custom backup transport script for **cPanel & WHM** on **AlmaLinux 8 / 9** (and Enterprise Linux distributions). This script enables automated, off-site cPanel backup storage in **Dropbox** using modern OAuth2 Refresh Tokens and chunked multipart uploads.

---

## Table of Contents

1. [Features](#features)
2. [Prerequisites & Installation](#prerequisites--installation)
3. [Dropbox App & OAuth2 Setup](#dropbox-app--oauth2-setup)
4. [WHM Backup Configuration](#whm-backup-configuration)
5. [Manual Usage: Uploading & Downloading Files](#manual-usage-uploading--downloading-files)
   - [CLI Argument Structure](#cli-argument-structure)
   - [Uploading Files (`put`)](#1-uploading-files-put)
   - [Downloading Files (`get`)](#2-downloading-files-get)
   - [Listing Files (`ls`)](#3-listing-files-ls)
   - [Creating Folders (`mkdir`)](#4-creating-folders-mkdir)
   - [Deleting Files (`delete`)](#5-deleting-files-delete)
   - [Deleting Folders (`rmdir`)](#6-deleting-folders-rmdir)
6. [Testing with cPanel's Backup Transporter](#testing-with-cpanels-backup-transporter)
7. [Troubleshooting](#troubleshooting)

---

## Features

- **OAuth2 Refresh Token Support**: Uses Dropbox offline access tokens. Automatically refreshes 4-hour temporary access tokens without manual intervention.
- **Token Caching**: Caches temporary tokens in `/tmp` with `0600` permissions, eliminating redundant API authorization calls across multi-step backup jobs.
- **Streaming Multipart Uploads**: Uploads large backups (>2 GB) in 16 MB chunks with 3-attempt retry backoff and unbuffered progress output to prevent cPanel connection timeouts.
- **Binary/XS Architecture Protection**: Correctly handles Perl `@INC` so dynamic modules (`IO.so`, `Socket.so`) do not throw `API version mismatch` errors across Perl updates.
- **External Configuration**: Stores credentials securely in `/etc/cpanel_dropbox.json` so you do not have to edit Perl script variables directly.

---

## Prerequisites & Installation

Run these commands as `root` on your AlmaLinux server:

### 1. Install System Build Tools & SSL Libraries
```bash
dnf install -y perl perl-CPAN perl-devel gcc make openssl-devel perl-LWP-Protocol-https perl-IO-Socket-SSL
```

### 2. Install the `WebService::Dropbox` Perl Module
Install into cPanel's internal Perl environment:
```bash
/usr/local/cpanel/3rdparty/bin/perl -MCPAN -e 'install WebService::Dropbox'
```

### 3. Install the Transport Script
```bash
cp backup_transport_dropbox.pl /usr/local/bin/backup_transport_dropbox.pl
chmod 755 /usr/local/bin/backup_transport_dropbox.pl
```

---

## Dropbox App & OAuth2 Setup

### Step 1: Create a Dropbox App
1. Go to the [Dropbox App Console](https://www.dropbox.com/developers/apps).
2. Click **Create app**:
   - Choose **Scoped access**.
   - Choose **Full Dropbox** (or **App folder** if you prefer isolating backups to `/Apps/your-app-name`).
   - Name the app (e.g., `cpanel-backups-hostname`).
3. Click the **Permissions** tab:
   - Check `files.content.write`
   - Check `files.content.read`
   - Check `files.metadata.write`
   - Check `files.metadata.read`
   - Click **Submit** at the bottom of the page.
4. On the **Settings** tab, note your **App key** and **App secret**.

### Step 2: Run the Interactive Setup Wizard
Run the script with the `--setup` flag:
```bash
/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl --setup
```

The wizard will:
1. Prompt for your **App Key** and **App Secret**.
2. Print an authorization URL to paste into your browser.
3. Ask you to paste the authorization code returned by Dropbox.
4. Exchange the code for a permanent **Refresh Token**.
5. Save the configuration to `/etc/cpanel_dropbox.json` with strict `0600` permissions.

*(To manually create `/etc/cpanel_dropbox.json`)*:
```json
{
  "app_key": "YOUR_APP_KEY",
  "app_secret": "YOUR_APP_SECRET",
  "refresh_token": "YOUR_PERMANENT_REFRESH_TOKEN"
}
```
```bash
chmod 600 /etc/cpanel_dropbox.json
```

---

## WHM Backup Configuration

1. Log into **WHM** as `root`.
2. Navigate to: **Home » Backup » Backup Configuration**.
3. Click the **Additional Destinations** tab.
4. Set **Destination Type** to **Custom**, then click **Create new destination**.
5. Fill in the fields:
   - **Destination Name**: `Dropbox`
   - **Script**: `/usr/local/bin/backup_transport_dropbox.pl`
   - **Backup Directory**: `/cpanel-backups` *(or any folder path on Dropbox)*
   - **Remote Host**: `dropbox` *(dummy placeholder)*
   - **Remote User**: `dropbox` *(dummy placeholder)*
   - **Remote Password**: `none` *(dummy placeholder)*
6. Click **Save and Validate Destination**.

---

## Manual Usage: Uploading & Downloading Files

You can invoke the script directly from the command line for manual operations, ad-hoc backup transfers, and restorations.

### CLI Argument Structure

cPanel custom transport scripts follow a standard argument order:

```bash
/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl <command> <current_remote_dir> [command_arguments...]
```

- `<command>`: The operation (`put`, `get`, `ls`, `mkdir`, `chdir`, `delete`, `rmdir`).
- `<current_remote_dir>`: The working base directory on Dropbox.
  - Use `""` or `"/"` if specifying absolute remote paths.
  - Or specify a base folder (e.g. `"/cpanel-backups"`), and paths will resolve relative to it.

---

### 1. Uploading Files (`put`)

Transfers a local file to Dropbox. Supports both small files and multi-gigabyte archives.

#### Syntax:
```bash
perl backup_transport_dropbox.pl put <remote_base_dir> <local_file_path> <remote_destination_filename>
```

#### Example A: Upload using a base directory
Uploads `/backup/2026-11-18/accounts/cpaneluser.tar.gz` to Dropbox path `/cpanel-backups/cpaneluser.tar.gz`:
```bash
/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl \
  put /cpanel-backups /backup/2026-11-18/accounts/cpaneluser.tar.gz cpaneluser.tar.gz
```

#### Example B: Upload with an absolute remote path (empty base dir)
Uploads `/home/backup.tar.gz` directly to `/archives/november/site_backup.tar.gz`:
```bash
/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl \
  put "" /home/backup.tar.gz /archives/november/site_backup.tar.gz
```

> **Note on large files**: During multipart uploads, the script prints progress dots (`....`) to standard output so that process monitors and shell sessions remain active.

---

### 2. Downloading Files (`get`)

Downloads a remote file from Dropbox to your local server (e.g., during account restoration).

#### Syntax:
```bash
perl backup_transport_dropbox.pl get <remote_base_dir> <remote_filename> <local_destination_path>
```

#### Example A: Download using a base directory
Downloads `/cpanel-backups/cpaneluser.tar.gz` from Dropbox to local `/tmp/cpaneluser.tar.gz`:
```bash
/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl \
  get /cpanel-backups cpaneluser.tar.gz /tmp/cpaneluser.tar.gz
```

#### Example B: Download with an absolute remote path
Downloads `/archives/november/database.sql.gz` from Dropbox to local `/root/restores/database.sql.gz`:
```bash
/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl \
  get "" /archives/november/database.sql.gz /root/restores/database.sql.gz
```

---

### 3. Listing Files (`ls`)

Lists remote folder contents in standard `ls -l` format.

#### Syntax:
```bash
perl backup_transport_dropbox.pl ls <remote_dir>
```

#### Example:
List everything inside `/cpanel-backups`:
```bash
/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl \
  ls /cpanel-backups
```

**Sample Output:**
```text
drwxr-xr-x 1 root root 0 Jan 01 00:00 2026-11-18
-rw-r--r-- 1 root root 104857600 Jan 01 00:00 cpaneluser.tar.gz
-rw-r--r-- 1 root root 524288000 Jan 01 00:00 system_files.tar.gz
```

To list the root directory:
```bash
/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl ls ""
```

---

### 4. Creating Folders (`mkdir`)

Creates a remote folder on Dropbox. If the folder already exists, the script safely succeeds without error (idempotent).

#### Syntax:
```bash
perl backup_transport_dropbox.pl mkdir <remote_base_dir> <new_folder_name>
```

#### Example:
Create folder `/cpanel-backups/weekly`:
```bash
/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl \
  mkdir /cpanel-backups weekly
```

---

### 5. Deleting Files (`delete`)

Deletes an individual file from Dropbox. If the file is already gone, it safely exits with `0`.

#### Syntax:
```bash
perl backup_transport_dropbox.pl delete <remote_base_dir> <file_to_delete>
```

#### Example:
Delete `/cpanel-backups/cpaneluser.tar.gz`:
```bash
/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl \
  delete /cpanel-backups cpaneluser.tar.gz
```

---

### 6. Deleting Folders (`rmdir`)

Recursively removes a directory from Dropbox (used by cPanel retention pruning).

#### Syntax:
```bash
perl backup_transport_dropbox.pl rmdir <remote_base_dir> <folder_to_delete>
```

#### Example:
Delete the folder `/cpanel-backups/2026-11-10`:
```bash
/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl \
  rmdir /cpanel-backups 2026-11-10
```

---

## Testing with cPanel's Backup Transporter

cPanel includes a built-in command-line tool to test custom destinations with actual backup files:

1. List configured destinations and copy your Dropbox Destination ID:
   ```bash
   whmapi1 backup_destination_list
   ```
2. Test a file upload directly through cPanel's queue runner:
   ```bash
   /usr/local/cpanel/bin/cpbackup_transport_file --transport <DESTINATION_ID> --upload /path/to/testfile.tar.gz
   ```
3. Monitor the backup transporter log:
   ```bash
   tail -f /usr/local/cpanel/logs/cpbackup_transporter.log
   ```

---

## Troubleshooting

| Error | Root Cause | Solution |
| :--- | :--- | :--- |
| `Cannot locate WebService/Dropbox.pm in @INC` | Perl module not installed in cPanel's environment. | Run `/usr/local/cpanel/3rdparty/bin/perl -MCPAN -e 'install WebService::Dropbox'` |
| `Perl API version v5.40.0 of IO.c does not match v5.42.0` | Perl loading compiled XS modules from mismatched versions. | Ensure you are using the updated script with `push @INC` and version-isolated paths. |
| `expired_access_token` | Using an old short-lived token without refresh capability. | Run `/usr/local/cpanel/3rdparty/bin/perl /usr/local/bin/backup_transport_dropbox.pl --setup` to generate a Refresh Token. |
| `missing_scope` (`files.content.write`) | Dropbox app does not have write permissions. | Open the Dropbox App Console, navigate to the **Permissions** tab, check `files.content.write` & `files.content.read`, and click **Submit**. Then re-run `--setup`. |
| `Connection Timeout` on large files | Upload chunk size too large for network speed. | The script uses 16 MB chunks with streaming STDOUT dots (`.`) to maintain transporter keep-alive. |
