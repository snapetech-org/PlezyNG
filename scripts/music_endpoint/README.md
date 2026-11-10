# Pleazyng music endpoint on Raspberry Pi

Use a 64-bit Pi OS and Pleazyng's Linux ARM64 package. This host runs the
ordinary profile-owned music player and encrypted companion listener without a
visible app window. The current Linux embedder still needs a virtual X11 display
(`xvfb` and `xauth`); audio uses the configured Linux output device.

1. Open Pleazyng normally as the same Linux user. Add the Plex server, select
   the intended profile, play a track, and close the app. A profile that needs
   an interactive unlock or selection on every launch will not host unattended.
2. Install `xvfb`, `xauth`, and the distribution's systemd user manager. From a
   packaged installation, run
   `/opt/pleazyng/data/music-endpoint/install.sh install /usr/bin/pleazyng`.
   From a portable bundle, run `data/music-endpoint/install.sh install ./pleazyng`.
3. Use Pleazyng's Companion Remote pairing on the controller to pair with the
   endpoint. A transfer is offered from Now Playing only after both devices
   advertise the compatible music-transfer version and the receiver can access
   every track in the transferred queue.

Run `install.sh status` for systemd status and recent journal entries. Run
`install.sh remove` to disable the unit; this keeps the profile and music data.
Package updates replace the Linux binary; restart the user unit after an update.
Rerunning the installer enables and restarts the service with the current
launcher. Status returns the service manager's exit code after printing logs.
Removal stops before deleting service files if disabling or stopping fails;
resolve the reported service-manager error and retry. Repeated removal is safe.
For boot startup without a user login, enable lingering for this user as shown
by the installer. The service does not grant access to locked profiles or copy
Plex tokens from a controller.
