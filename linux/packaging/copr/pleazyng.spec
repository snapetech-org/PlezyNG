Name:           pleazyng
Version:        2.24.1
Release:        2%{?dist}
Summary:        Plex client with Jellyfin and Emby support, offline downloads, and HDR
License:        GPL-3.0-only
URL:            https://github.com/snapetech-org/pleazyng
Source0:        pleazyng-linux-x64.tar.gz
Source1:        pleazyng-linux-arm64.tar.gz
Source2:        pleazyng.sh
Source3:        org.snapetech.pleazyng.desktop
Source4:        pleazyng.png
Source5:        LICENSE
Source6:        normalize-bundle-rpaths.py
Source7:        relocate-caches.py
BuildRequires:  tar
BuildRequires:  patchelf
BuildRequires:  python3
Requires:       gtk3
Requires:       webkit2gtk4.1
Requires:       libsecret
Requires:       libepoxy
Requires:       alsa-lib
Requires:       libevdev
Requires:       glib2
Requires:       libwayland-client
Requires:       libwayland-cursor
Requires:       libwayland-egl
Requires:       libwayland-server
Requires:       libglvnd
Requires:       libglvnd-egl
Requires:       libglvnd-glx
Requires:       libva
Requires:       libvdpau
Requires:       vulkan-loader
Requires:       libdrm
Requires:       mesa-libgbm
Requires:       libX11
Requires:       libX11-xcb
Requires:       libXext
Requires:       libxcb
ExclusiveArch:  x86_64 aarch64
AutoReqProv:    no

%description
Pleazyng is an enhanced Plex client that also supports Jellyfin and Emby. Browse
movies, shows, and music across your servers, search connected libraries, and
keep watchlists and viewing progress in sync. Download media for offline
playback. Watch Live TV and DVR where your server supports them. Choose audio
tracks and subtitles, adjust playback speed and audio sync, and use HDR or
Dolby Vision on supported devices. Watch Together keeps playback in sync when
everyone can access the same media on the same server. Use Pleazyng on phones,
tablets, TVs, and desktop computers. You’ll need your own Plex, Jellyfin, or
Emby server. Features vary by server, device, and media.

%prep
%setup -q -c -T
%ifarch x86_64
tar -xzf %{SOURCE0} -C .
%else
tar -xzf %{SOURCE1} -C .
%endif

%build

%install
install -d %{buildroot}/opt/pleazyng
cp -a . %{buildroot}/opt/pleazyng/
python3 %{SOURCE6} %{buildroot}/opt/pleazyng
python3 %{SOURCE7} %{buildroot}/opt/pleazyng --runtime-prefix /opt/pleazyng
install -Dm755 %{SOURCE2} %{buildroot}/usr/bin/pleazyng
install -Dm644 %{SOURCE3} %{buildroot}/usr/share/applications/org.snapetech.pleazyng.desktop
install -Dm644 %{SOURCE4} %{buildroot}/usr/share/icons/hicolor/512x512/apps/pleazyng.png
install -Dm644 %{SOURCE5} %{buildroot}/usr/share/licenses/%{name}/LICENSE
chmod 0755 %{buildroot}/opt/pleazyng/pleazyng %{buildroot}/opt/pleazyng/lib/crashpad_handler

%post
/bin/chmod 0755 /opt/pleazyng/pleazyng /opt/pleazyng/lib/crashpad_handler 2>/dev/null || :

%files
/opt/pleazyng
/usr/bin/pleazyng
/usr/share/applications/org.snapetech.pleazyng.desktop
/usr/share/icons/hicolor/512x512/apps/pleazyng.png
%license /usr/share/licenses/%{name}/LICENSE
