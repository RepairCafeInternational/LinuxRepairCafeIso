# Linux Mint Auto-Install ISO
         
This repository contains all the files required to build the automated installation ISO image for the Linux Repair Café project.  

A preseed file is a configuration file that provides answers to the questions normally asked by the Linux Mint installer.  
It is the standard method for performing automatic installations on Debian-based distributions.  
Using this approach, you can create a fully automatic installation ISO that includes custom software and configuration.

To apply these customizations, we need to build a new installation ISO.  
This ISO will boot on both MBR and EFI systems.  

## Download pre made ISOs

Download the latest iso's on [sourceforge](https://sourceforge.net/projects/linux-iso).  
NOTE:
The iso's come in two versions, the regular version and the [HWE](https://www.linuxmint.com/hwe.php) version.  
HWE stands for Hardware Enablement. These images include a kernel which is newer than the one in the regular ISO, to improve compatibility with more recent hardware.  
It is recommended to first use the regular version.  
When you run into hardware detection problems you can try the HWE version.

## Changes from the default install

    - Fully automated install
    - Automatic partititioning on first harddisk
    - Unattended software updates
    - Install the non-free mint-meta-codecs
    - A manual is placed on the user's desktop
    - Install cheese to test webcam support
    
## Available language packs
The following languages are available for offline install:

    - English (en)
    - German (de)
    - Spanish (es)
    - French (fr)
    - Italian (it)
    - Dutch (nl)
    - Portuguese (pt)
    - Russian (ru)

## Using the ISO

When you boot from the ISO, you’ll be presented with the following options:

1. **Start Linux Mint**  
   Start a live environment where you can try the system without installing.  
   Includes a few extra tools (e.g., *Cheese* for testing webcam support).

2. **Automated OEM install - Install on first disk**  
   Installs the system to the first available non-removabledisk using default settings,  
   without asking for confirmation.

3. **Automated OEM install - Manual partitioning**  
   Similar to the automatic install, but allows you to define your own partition layout.  


## Verify the ISO
When downloading an installation ISO you should always verify it.  
This ensures the file really comes from the Linux Repair Café project and has not been tampered with.  

Verification requires three files and a public key.  

    lrc-linuxmint-FLAVOR-VERSION-YYYY.MM.DD.iso
    lrc-linuxmint-FLAVOR-VERSION-YYYY.MM.DD.iso.sha256
    lrc-linuxmint-FLAVOR-VERSION-YYYY.MM.DD.iso.sha256.gpg

For every ISO release you can find these files on our sourceforge page.  

### Import the public key from the repair cafe website

    curl -s https://www.repaircafe.org/wp-content/uploads/2025/10/Linux_Repair_Cafe_Pubkey.txt | gpg --import

    # Check that the public key was properly imported
    gpg --list-keys

### Verify the public key's fingerprint
We publish the official GPG fingerprint on this GitHub page and other trusted places.  
After importing our public key, check its fingerprint:  

    # The fingerprint should correspond to the repair cafe fingerprint.
    # 829C A1EF E0E9 28CA 7587  2A41 8D8D F1CA 6F15 E39F
    gpg --fingerprint <KEYID>

### Verify the authenticity of the checksum
We sign the *.sha256sum file with our private GPG key.  
You verify it using our public key:  

    gpg --verify lrc-linuxmint-FLAVOR-VERSION-YYYY.MM.DD.iso.sha256sum.gpg \
                 lrc-linuxmint-FLAVOR-VERSION-YYYY.MM.DD.iso.sha256sum

### Checksum proves the ISO
Finally, check that the ISO’s SHA-256 hash matches the signed checksum.  
If they match, the ISO is guaranteed to be exactly the one we released.  

    # Place all files in the same directory.
    # This should return an OK
    sha256sum --check lrc-linuxmint-FLAVOR-VERSION-YYYY.MM.DD.iso.sha256


## Create install ISO
Note: this method is tested on debian trixie.  
Ready made iso files can be downloaded from the sourceforge link above but if you want to make your own you can follow this method.  

To ensure a consistent build environment, a Dockerfile for docker is provided in this repository.  

### Requirements
- [Download](https://www.linuxmint.com/download.php) the LTS version of the linux mint install ISO.   
- [Docker](https://www.docker.com/) needs to be installed on the host system.  

### Clone repository

    # Install git if it isn't already installed
    sudo apt install git

    # Clone this git repository
    git clone https://github.com/RepairCafeInternational/LinuxRepairCafeIso

### Building the ISO
The Dockerfile will automatically be built when running the docker_builder.sh script.  

    cd path/to/repo
    ./docker_builder.sh -i /path/to/img.iso -o /path/to/dest/dir

### Write ISO to usb stick
Linux Mint recommends GUI programs for writing ISO files: https://linuxmint-installation-guide.readthedocs.io/en/latest/burn.html  

#### The manual way
Find the device file for your usb stick (probably something like /dev/sdx)  
In my case this is */dev/sdb*.  

    $ lsblk                                                                                                             20:18:16
    NAME         MAJ:MIN RM   SIZE RO TYPE  MOUNTPOINTS
    sda            8:0    0 931,5G  0 disk
    ├─sda1         8:1    0   511M  0 part  /boot
    └─sda2         8:2    0   931G  0 part
    └─cryptlvm 254:0    0   931G  0 crypt /
    sdb            8:16   1  28,7G  0 disk
    sdc            8:32   1     0B  0 disk
    sdd            8:48   1     0B  0 disk
    zram0        253:0    0     4G  0 disk  [SWAP]

Write the new iso file to an unmounted USB stick.  
Be very carefull, [dd](https://www.man7.org/linux/man-pages/man1/dd.1.html) doesn't ask any questions before writing to a device.  
It will write over your system disk without any problems ;)  

    # NOTE: Replace <DEVICE> with the path to your USB stick's device file
    sudo dd if=/path/to/img.iso of=/dev/<DEVICE> bs=8M status=progress

The linuxmint_custom.seed file is copied to the ISO.  
When booting from this USB stick, a new boot menu option becomes available: "Automated OEM install".  
During this OEM install the preseed file is read and the install should be completely silent.  


## References
https://wiki.syslinux.org/wiki/index.php?title=Isohybrid  
https://github.com/Pauchu/linux-mint-20-preseeding  
Example debian preseed config [options](https://www.debian.org/releases/bookworm/example-preseed.txt)   
https://gitlab.com/morph027/preseed-cinnamon-ubuntu  
https://linuxconfig.org/how-to-perform-unattedended-debian-installations-with-preseed  
https://wiki.ubuntu.com/UbiquityAutomation  
https://wiki.ubuntu.com/DebuggingUbiquity  
