#!/bin/sh
set -eu
dest="${1:?usage: fetch-raw-samples.sh DIR}"
mkdir -p "$dest"
fetch() {
    if [ -f "$dest/$2" ] && echo "$3  $dest/$2" | sha256sum -c --status; then return 0; fi
    curl -fsSL -o "$dest/$2.part" "$1"
    echo "$3  $dest/$2.part" | sha256sum -c --status
    mv "$dest/$2.part" "$dest/$2"
}
fetch 'https://raw.pixls.us/getfile.php/862/nice/Canon%20-%20EOS%20650D%20-%20RAW%20(3:2).CR2' 'sample.cr2' 8a0038f8bc0506bf2543dda0b05422e359b6e11e802e789e345ba2339b2f37e1
fetch 'https://raw.pixls.us/getfile.php/4656/nice/Canon%20-%20EOS%20M50%20-%203:2.CR3' 'sample.cr3' 27a88fdae82516ba136e12c2cc9b934f25dbaaac24d64ab4e5517f8524463594
fetch 'https://raw.pixls.us/getfile.php/2516/nice/Nikon%20-%20D500%20-%2012bit%2012bit%20compressed%20(Lossless)%20(3:2).NEF' 'sample.nef' 4c9ca014c09bad1c945a2ca5d0532207a99b274419117c52ce6b700246d6bab6
fetch 'https://raw.pixls.us/getfile.php/1536/nice/Sony%20-%20ILCE-7%20-%2014bit%2014bit%20compressed%20(3:2).arw' 'sample.arw' c242df04d4a0e246130600e102371d4aea2e7eeac35c1e65c4757191dcb7cd33
fetch 'https://raw.pixls.us/getfile.php/1214/nice/Fujifilm%20-%20X-A1%20-%2012bit%2012bit%20uncompressed%20(3:2).RAF' 'sample.raf' b2ddb5fe31a3b976d12961c72a2689de8742739df3d8f757614eca65f8df2a61
fetch 'https://raw.pixls.us/getfile.php/4927/nice/Olympus%20-%20E-M10%20Mark%20IIIs%20-%2016bit%20(4:3).ORF' 'sample.orf' 8bc0009eaacdbeacc72606581665702a1242bc6d4b405d1f0b3f149fe6c85e55
fetch 'https://raw.pixls.us/getfile.php/6821/nice/Panasonic%20-%20DMC-GM1S%20-%201:1.RW2' 'sample.rw2' c9ec448cb0132fe8cab6a427cf0aaeb6f9f251450b1420de0774658e7f4b067e
