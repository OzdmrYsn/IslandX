# IslandX

[Türkçe](#türkçe) · [English](#english) · [Website](https://ozdmrysn.github.io/IslandX/) · [Releases](https://github.com/OzdmrYsn/IslandX/releases)

IslandX brings Music and Spotify controls to the top of macOS. It blends into the camera notch on compatible MacBooks and becomes a compact floating island on other displays.

> Minimum system: macOS 13 · Universal binary: Apple Silicon + Intel

## Türkçe

IslandX, Music ve Spotify kontrollerini MacBook'un kamera çentiğiyle bütünleştiren SwiftUI + AppKit uygulamasıdır. Çentik olmayan ekranlarda ekranın üst-ortasında zarif bir yüzen ada olarak görünür.

### Özellikler

- Kamera çentiğini ve ekran güvenli alanını otomatik algılama
- Görünür Ada ve çentiğin içine tamamen saklanan Gizli Mini boşta modları
- Akıcı kompakt/genişletilmiş görünüm geçişi
- Music ve Spotify parça, sanatçı ve kapak bilgileri
- Oynat/duraklat, önceki/sonraki, karışık çal, tekrar, ilerleme ve sistem sesi kontrolleri
- Üzerine gelme, tıklama veya çentiğin orta etkin alanıyla seçilebilir açılma davranışı
- Şarkı değiştiğinde süreli gösterim ve tam ekran uygulamalarda isteğe bağlı gizleme
- Albüm kapağı veya kaynak rozetinden çalan parçayı Music/Spotify'da açma
- Sistem, Beyaz, Siyah ve desteklenen macOS sürümlerinde Liquid Glass görünümü
- Türkçe/İngilizce ilk kurulum rehberi
- Açılışta başlatma ve Sparkle tabanlı imzalı güncellemeler
- Tüm Spaces ve tam ekran uygulamalarla çalışma

### Kurulum

1. [IslandX DMG dosyasını](https://github.com/OzdmrYsn/IslandX/releases/latest/download/IslandX.dmg) indirin ve açın.
2. `IslandX.app` uygulamasını aynı penceredeki **Applications / Uygulamalar** kısayoluna sürükleyin.
3. İlk açılışta uygulamaya Control-tıklayıp **Aç** seçeneğini kullanın.
4. Music veya Spotify kontrolü için macOS'un istediği **Automation** iznine onay verin.

Apple Developer ID ile notarizasyon henüz tamamlanmadığı için ilk açılışta macOS güvenlik uyarısı gösterebilir. Control-tıklama > Aç işlemi uygulama için kalıcı onay oluşturur.

### Kaynaktan çalıştırma

1. `IslandX.xcodeproj` dosyasını Xcode ile açın.
2. IslandX target'ında **Signing & Capabilities** bölümünden kendi Team'inizi seçin.
3. Uygulamayı çalıştırıp Music veya Spotify'da bir parça başlatın.

## English

IslandX is a SwiftUI + AppKit app that blends Music and Spotify controls into the MacBook camera notch. On displays without a notch, it appears as an elegant floating island at the top center of the screen.

### Features

- Automatic camera-notch and safe-area detection
- Visible Island and fully concealed Hidden Mini idle modes
- Fluid compact/expanded transitions
- Track, artist, and artwork from Music and Spotify
- Play/pause, previous/next, shuffle, repeat, progress, and system-volume controls
- Selectable hover, click, or center-zone opening behavior
- Timed track-change previews and optional hiding over full-screen apps
- Open the current track in Music or Spotify from its artwork or source badge
- System, White, Black, and Liquid Glass appearances on supported macOS versions
- Turkish and English first-run guide
- Launch at login and signed Sparkle updates
- Works across Spaces and over full-screen apps

### Installation

1. Download and open the latest [IslandX DMG](https://github.com/OzdmrYsn/IslandX/releases/latest/download/IslandX.dmg).
2. Drag `IslandX.app` onto the **Applications** shortcut in the same window.
3. On first launch, Control-click the app and choose **Open**.
4. Approve the macOS **Automation** request to control Music or Spotify.

The app is not yet notarized with an Apple Developer ID, so macOS may show a security warning on first launch. Control-click > Open creates a permanent approval for the app.

### Run from source

1. Open `IslandX.xcodeproj` in Xcode.
2. Select your own Team under the IslandX target's **Signing & Capabilities** settings.
3. Run the app and start a track in Music or Spotify.

## Architecture

- `AppDelegate.swift` / `WindowController.swift`: transparent `NSPanel`, Spaces/full-screen behavior, screen observation, and positioning
- `AppSettings.swift`: persistent language, theme, hover behavior, launch-at-login, and onboarding state
- `MediaManager.swift`: AppleScript integration, reactive media state, artwork, playback, and system volume
- `DynamicNotchView.swift`: adaptive notch geometry, morph animation, themes, and media controls
- `UpdateManager.swift`: Sparkle update checks and automatic-update preferences
- `OnboardingView.swift`: bilingual first-run experience

## Updates and releases

IslandX uses Sparkle 2 with an EdDSA-signed appcast. The private key remains in the developer's macOS Keychain and must never be committed.

To prepare a new release:

1. Increase `CFBundleShortVersionString` and `CFBundleVersion`.
2. Run `scripts/create-release.sh`.
3. Upload `dist/IslandX-VERSION.zip` and `dist/IslandX.dmg` to a GitHub Release tagged `vVERSION`.
4. Commit and publish the regenerated `appcast.xml` after the ZIP is available.

Developer ID signing and notarization are recommended for polished public distribution. The current ad-hoc signature is intended for development and early GitHub releases.

---

<sub><a href="https://github.com/OzdmrYsn">github.com/OzdmrYsn</a> | Yasin Özdemir</sub>
