# NASA APOD Explorer

## Setup
1. Install Flutter SDK and run `flutter doctor`.
2. Run dependency install.
3. Launch app on Android/iOS.
4. On first launch, open `https://api.nasa.gov/`, create a free API key, and paste it into the app.
5. Optional guarded runner: `python scripts/flutter_guard.py run -d windows --timeout 180`

## Features
- Secure API key onboarding and validation
- Today/date/random APOD fetch
- Image and video APOD handling
- Immersive home view with auto-hiding top controls
- Optional info-panel hide mode (media-only with title chip)
- Directional slideshow (start date + forward/backward + runtime)
- Slideshow controls and pre-cache window
- Cache clear and slideshow settings
- Android wallpaper set, iOS image save for manual wallpaper
