# For new computers:
  Delete all extra MacOS apps: Garage Band, iMovie, Keynote, Numbers, Pages, etc.
  
  Update all apps through the App Store (in the Updates section and Featured section for the latest OS, multiple times if needed).

# System Preferences:
  General
    Appearance: Dark
    Default browser: Brave
  Desktop & Screen Saver:
    Screen Saver:
      Start after: Never
      Hot Corners:
        Top Left: Application Windows
  Dock & Menu Bar:
    Size: [---x-----]
    [ ] Magnification
    [x] Automatically hide and show the Dock
    [ ] Show recent applications in Dock
    [x] Automatically hide and show the menu bar on desktop
    [x] Automatically hide and show the menu bar in full screen
  Mission Control:
    [ ] Automatically rearrange Spaces bases on most recent use
    [x] When switching to an app, switch to a Space
    [ ] Group windows by application
    [x] Displays have separate Spaces
    Mission Control: ^↑
    Application windows: ^↓
  Siri:
    Turn off
  Spotlight:
    Search Results:
      [x] Applications
      [x] Calculator
      [x] System Preferences
      Uncheck all others
    Privacy:
      Remove everything
  Extensions:
    Share Menu:
      [x] Copy Link
      [x] Annotate (CleanShotX option)
      Uncheck all other
  Language & Region:
    Time format: 24-Hour Time
    Live Text: [ ] Select Text in Images
  Bluetooth:
    [x] Show Bluetooth in menubar
  Sound:
    [ ] Show volume in menu bar
  Keyboard:
    Keyboard:
      Key Repeat: Fast (before the last one)
      Delay Until Repeat: Fast
      [x] Turn keyboard backlight off after 30 secs of inactivity
      Press Fn to: Do Nothing
    Modifier Keys:
      Caps Lock: No Action
      Fn key: Fn function
      Globe key: Globe
    Text:
      [ ] Touch Bar typing suggestions
      [ ] Use smart quotes and dashes
    Shortcuts:
      Launchpad & Doc:
        Uncheck All
      Mission Control:
        [ ] Show Notification Centre
        [ ] Quick Note
      Input Sources
        [x] Select the previous input source
        [ ] Select next source in Input menu
      Screenshots:
        Uncheck All
      Services:
        Uncheck All
      Spotlight:
        Uncheck All
      Accessibility:
        Uncheck All
    Input Sources:
      English - Strata Markdown
      Russian - Strata Markdown
      [x] Show Input menu in menu bar
  Trackpad:
    Point & Click:
      [ ] Look up & data detectors
      [x] Secondary click: two fingers
      [x] Tap to click
      [x] Silent clicking
      [ ] Force Click and haptic feedback
    Scroll & Zoom:
      [x] Scroll direction: Natural
      [ ] Zoom in or out
      [ ] Smart zoom
      [ ] Rotate
    More Gestures:
      [x] Swipe between pages: two fingers
      [x] Swipe between full-screen apps: three fingers
      [ ] Notification Centre
      [x] Mission Control: three fingers
      [x] App Expose: three fingers
      [ ] Launchpad
      [x] Show Desktop: thumb and three fingers
  Displays:
    Display > Resolution: Scaled (middle one)
    [x] Automatically adjust brightness
    [ ] True Tone
    [ ] Show mirroring options in the menu bar when available
    Night Shift
      Schedule: Sunset to Sunrise
      [ ] Manual
  Battery:
    Battery:
      Turn display off after: 15 min
      [x] Put hard disks to sleep when possible
      [ ] Slightly dim the display while on battery
      [ ] Enable Power Nap while on battery power
      [x] Automatic graphics switching
      [ ] Optimise video streaming while on battery
      [x] Optimise battery charging
      [ ] Show battery status in menu bar
      [ ] Low power mode
    Power Adapter:
      Turn display off after: 30 min
      [ ] Prevent computer from sleeping automatically when the display is off
      [x] Put hard disks to sleep when possible
      [ ] Wake for network access
      [ ] Enable Power Nap while on battery power
      [ ] Low power mode
  Users & Groups:
    Login Items:
      Android File Transfer Agent
      noTunes
      MTMR
      Hammerspoon
      Dropbox
      Endurance

# Finder Preferences:
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