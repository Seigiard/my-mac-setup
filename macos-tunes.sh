# Show system info (hostname, IP, macOS version) when clicking the clock on login screen
sudo defaults write /Library/Preferences/com.apple.loginwindow AdminHostInfo HostName

# ==============================================================================
# System Appearance & Siri
# ==============================================================================

# Set dark mode appearance
# defaults write NSGlobalDomain AppleInterfaceStyle -string "Dark"

# Disable the startup chime sound
# sudo nvram SystemAudioVolume=" "

# Disable Siri
defaults write com.apple.assistant.support "Assistant Enabled" -bool false
# Remove Siri icon from menu bar
defaults write com.apple.Siri StatusMenuVisible -bool false
defaults write com.apple.Siri UserHasDeclinedEnable -bool true

# ==============================================================================
# Keyboard & Input
# ==============================================================================

# Enable full keyboard access for all UI controls (Tab navigates all controls)
defaults write NSGlobalDomain AppleKeyboardUIMode -int 3

# Set system languages (English primary, Russian secondary)
defaults write NSGlobalDomain AppleLanguages -array en ru

# Disable press-and-hold for accents popup, enabling key repeat instead
defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false

# Set delay before key repeat starts (15 = 225ms)
defaults write NSGlobalDomain InitialKeyRepeat -int 15

# Set key repeat rate (2 = 30ms between repeats)
defaults write NSGlobalDomain KeyRepeat -int 2

# Disable automatic spelling correction
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false

# Disable the input source indicator popup when switching keyboard layouts
defaults write kCFPreferencesAnyApplication TSMLanguageIndicatorEnabled 0

# ==============================================================================
# Dock
# ==============================================================================

# Disable Dock magnification
defaults write com.apple.dock magnification -bool false

# Set minimize animation to "scale" effect
defaults write com.apple.dock mineffect -string scale
defaults write com.apple.dock expose-animation-duration -float 0

# Position the Dock on the right side of screen
defaults write com.apple.dock orientation -string right

# Show indicator dots for open applications
defaults write com.apple.dock show-process-indicators -bool true

# Enable spring loading for Dock items (drag files over apps to open them)
defaults write com.apple.dock enable-spring-load-actions-on-all-items -bool true

# Disable automatic rearrangement of Spaces based on most recent use
defaults write com.apple.dock mru-spaces -bool false

# Hide "Recent Applications" section in Dock
defaults write com.apple.dock show-recents -bool false

# Disable bounce animation when launching apps from Dock
defaults write com.apple.dock launchanim -bool false

# Remove delay before Dock appears when auto-hidden (default: 0.5s)
defaults write com.apple.dock autohide-delay -float 0

# Remove Dock show/hide animation (default: 0.5s)
defaults write com.apple.dock autohide-time-modifier -float 0

# Enable Dock auto-hide
defaults write com.apple.dock autohide -bool true

# Disable Dashboard (obsolete - removed in macOS Catalina 10.15)
defaults write com.apple.dashboard mcx-disabled -bool true
defaults write com.apple.dock dashboard-in-overlay -bool true

# Set Dock icon size
defaults write com.apple.dock tilesize -int 64

# ==============================================================================
# Menu Bar
# ==============================================================================

# Auto-hide menu bar on desktop
defaults write NSGlobalDomain _HIHideMenuBar -bool false

# ==============================================================================
# Mission Control
# ==============================================================================

# Don't group windows by application in Mission Control
defaults write com.apple.dock expose-group-apps -bool false

# ==============================================================================
# Windows & Tabs
# ==============================================================================

# Prefer tabs when opening documents: Always
defaults write NSGlobalDomain AppleWindowTabbingMode -string "always"

# Expand save dialog by default (show full file browser, not compact view)
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true

# Expand print dialog by default (show all options, not compact view)
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true

# Save new documents to local disk by default instead of iCloud
defaults write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false

# Auto-quit printer app when all print jobs complete
defaults write com.apple.print.PrintingPrefs "Quit When Finished" -bool true

# ==============================================================================
# Finder
# ==============================================================================

# Add "Quit Finder" option to Finder menu (⌘Q)
defaults write com.apple.finder QuitMenuItem -bool true

# Set default Finder view to List view (Nlsv)
defaults write com.apple.finder FXPreferredViewStyle -string Nlsv

# Disable all Finder window animations (opening, closing, Get Info, etc.)
defaults write com.apple.finder DisableAllAnimations -bool true

# Show hidden files in Finder (toggle with ⌘⇧.)
defaults write com.apple.Finder AppleShowAllFiles -bool true

# Show all filename extensions
defaults write NSGlobalDomain AppleShowAllExtensions -bool true

# Keep folders on top when sorting by name in Finder windows
defaults write com.apple.finder _FXSortFoldersFirst -bool true

# Keep folders on top when sorting by name on Desktop
defaults write com.apple.finder _FXSortFoldersFirstOnDesktop -bool true

# Set default search scope to current folder (SCcf) instead of "This Mac"
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"

# Disable warning dialog when changing a file extension
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

# Automatically empty Trash after 30 days
defaults write com.apple.finder FXRemoveOldTrashItems -bool true

# New Finder windows show Downloads folder
defaults write com.apple.finder NewWindowTarget -string "PfLo"
defaults write com.apple.finder NewWindowTargetPath -string "file://${HOME}/Downloads/"

# Show path bar at bottom of Finder windows
defaults write com.apple.finder ShowPathbar -bool true

# Hide all desktop icons (external drives, servers, removable media)
defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool false
defaults write com.apple.finder ShowHardDrivesOnDesktop -bool false
defaults write com.apple.finder ShowMountedServersOnDesktop -bool false
defaults write com.apple.finder ShowRemovableMediaOnDesktop -bool false

# Always show proxy icons in window title bars (instead of hover-to-reveal)
defaults write com.apple.universalaccess showWindowTitlebarIcons -bool true

# ==============================================================================
# Spring Loading & .DS_Store
# ==============================================================================

# Enable spring loading: folders open when dragging items over them
defaults write NSGlobalDomain com.apple.springing.enabled -bool true

# Set spring loading delay to 0 (instant folder opening when hovering)
defaults write NSGlobalDomain com.apple.springing.delay -float 0

# Prevent creation of .DS_Store files on network volumes (SMB, AFP, NFS, WebDAV)
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true

# Prevent creation of .DS_Store files on USB/removable drives
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true

# ==============================================================================
# Text Input & Typing
# ==============================================================================

# Disable automatic capitalization of first letter
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false

# Disable smart dashes (-- to em-dash conversion)
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false

# Disable automatic period insertion with double-space
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false

# Disable smart quotes (straight to curly quotes conversion)
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false

# ==============================================================================
# Trackpad
# ==============================================================================

# Enable tap to click
defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true

# Enable natural scrolling
defaults write NSGlobalDomain com.apple.swipescrolldirection -bool true

# ==============================================================================
# Screenshots
# ==============================================================================

# Disable drop shadow in window screenshots (⌘⇧4 then Space)
defaults write com.apple.screencapture disable-shadow -bool true

# ==============================================================================
# Disk Images
# ==============================================================================

# Skip verification when mounting disk images
defaults write com.apple.frameworks.diskimages skip-verify -bool true
defaults write com.apple.frameworks.diskimages skip-verify-locked -bool true
defaults write com.apple.frameworks.diskimages skip-verify-remote -bool true

# ==============================================================================
# Security & Privacy
# ==============================================================================

# Disable "Application downloaded from internet" quarantine warning (may not work on Big Sur+)
defaults write com.apple.LaunchServices LSQuarantine -bool false

# ==============================================================================
# Developer Tools
# ==============================================================================

# Enable "Inspect Element" context menu in WebKit-based apps
defaults write NSGlobalDomain WebKitDeveloperExtras -bool true

# ==============================================================================
# TextEdit
# ==============================================================================

# Use plain text mode for new TextEdit documents
defaults write com.apple.TextEdit RichText -int 0

# Set default encoding for plain text files to UTF-8
defaults write com.apple.TextEdit PlainTextEncoding -int 4
defaults write com.apple.TextEdit PlainTextEncodingForWrite -int 4

# ==============================================================================
# Animations (disable for speed)
# ==============================================================================

# Disable animations when opening and closing windows and popovers
defaults write -g NSAutomaticWindowAnimationsEnabled -bool false

# Speed up window resize animations (0.001s instead of default)
defaults write -g NSWindowResizeTime -float 0.001
defaults write NSGlobalDomain NSWindowResizeTime -float 0.001

# Disable Quick Look window open/close animations
defaults write -g QLPanelAnimationDuration -float 0

# ==============================================================================
# Apply Changes
# ==============================================================================

killall Dock
killall Finder
killall SystemUIServer
