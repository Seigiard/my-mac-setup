# For new computers:
  Delete all extra MacOS apps: Garage Band, iMovie, Keynote, Numbers, Pages, etc.

  Update all apps through the App Store (in the Updates section and Featured section for the latest OS, multiple times if needed).
# System Settings:
  Appearance
    Appearance: Dark
  Siri & Spotlight:
    Turn off
    Spotlight:
      Search Results:
        [x] Applications
        [x] Calculator
        [x] System Preferences
        Uncheck all others
      Privacy:
        Remove everything
  Desktop & Dock
    Dock:
      Size: [---x-----]
      Magnification: Off
      Position on Screen: Right
      Minimise windows using: Scale Effect
      [x] Automatically hide and show the Dock
      [ ] Animate opening applications
      [x] Show indicators for opening apps
      [ ] Show suggested and recent apps in in Dock
      [x] Automatically hide and show the menu bar on desktop
      [x] Automatically hide and show the menu bar in full screen
    Desktop & Stage Manager
      Show items: On Desktop
      Stage Manager: All off
    Widgets:
      All off
    Default browser: Floorp/Brave
    Windows:
      Prefer tabs when opening documents: Always
    Mission Control:
      [ ] Automatically rearrange Spaces bases on most recent use
      [x] When switching to an app, switch to a Space
      [ ] Group windows by application
      [x] Displays have separate Spaces
      Mission Control: ^↑
      Application windows: ^↓
  Screen Saver:
    Screen Saver:
      Start after: Never
  Extensions:
    Share Menu:
      [x] Copy Link
      [x] Annotate (CleanShotX option)
      Uncheck all other
  Language & Region:
    Time format: 24-Hour Time
    Live Text: [x] Select Text in Images
  Bluetooth:
    [x] Show Bluetooth in menubar
  Sound:
    [ ] Play sound on startup
    [ ] Play user interface sound effects
    [x] Play feedback when volume is changed
  Keyboard:
    Keyboard:
      Key Repeat: Fast (before the last one)
      Delay Until Repeat: Short (before the last one)
      [ ] Ajust keyboard brightness in low light
      Turn keyboard backlight off after inactivity: 5 sec
      Press Fn to: Do Nothing
    Keyboard Shortcuts:
      Launchpad & Doc:
        Uncheck All
      Display:
        Uncheck All
      Mission Control:
        Uncheck All except:
        [x] Mission Control
        [x] Application windows
      Keyboard
        Uncheck All except:
        [x] Move focus to the next window
      Input Sources
        Uncheck All
      Screenshots:
        Uncheck All
      Presenter Overlay:
        Uncheck All
      Services:
        Uncheck All
      Spotlight:
        Uncheck All
      Accessibility:
        Uncheck All
    Text Input → Edit:
      Input Sources:
        English - Strata Markdown
        Russian - Strata Markdown
      Settings
        [x] Show Input menu in menu bar
        [ ] Touch Bar typing suggestions
        [ ] Use the Caps Lock key to Switch
        [ ] Automatically switch to a document's input source
        [ ] Use smart quotes and dashes
  Trackpad:
    Point & Click:
      [x] Silent clicking
      [ ] Force Click and haptic feedback
      [ ] Look up & data detectors
      [x] Secondary click: two fingers
      [x] Tap to click
    Scroll & Zoom:
      [x] Scroll direction: Natural
      [ ] Zoom in or out
      [ ] Smart zoom
      [ ] Rotate
    More Gestures:
      [x] Swipe between pages: two fingers
      [x] Swipe between full-screen apps: three fingers
      [ ] Notification Centre
      [x] Mission Control: Swipe up with three fingers
      [x] App Expose: Swipe down with three fingers
      [ ] Launchpad
      [x] Show Desktop: thumb and three fingers
  Displays:
    Display > Resolution: Scaled (middle one)
    [x] Automatically adjust brightness
    [x] True Tone
    [ ] Show mirroring options in the menu bar when available
    Night Shift
      Schedule: Sunset to Sunrise
      [ ] Manual
  Users & Groups:
    Login Items:
      noTunes
      MTMR
      Hammerspoon
      Dropbox
      CleanShotX

# Finder Settings:
  General:
    Show these items on the desktop: uncheck all.
    New Finder windows show: Downloads
  Sidebar:
    Applications, Downloads, %{USERNAME_HOME_FOLDER}, Hard disks, External disks
  Advanced:
    [x] Show all filename extensions
    [x] Keep folders on top when sorting by name
  Show hidden files: Cmd + Shift + .
  Sidebar Favorites:
    Downloads
    Movies
    %{USERNAME} (home folder)
    Applications
    Dropbox

# Dock Apps:
  Open Apps
  |
  Downloads (Sort by: Date Added, Display as: Stack, View content as: Fan)
  Trash

# Dock auto-hide times:
  Set to custom:
    defaults write com.apple.dock autohide-delay -int 0
    defaults write com.apple.dock autohide-time-modifier -float 0.5
    killall Dock
  Restore defaults:
    defaults delete com.apple.dock autohide-delay
    defaults delete com.apple.dock autohide-time-modifier
    killall Dock
