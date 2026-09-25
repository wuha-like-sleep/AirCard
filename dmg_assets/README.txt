============================================================
              AirCard · Quick Start Guide
============================================================

1. INSTALLATION
   Drag the "AirCard" icon onto the "Applications" folder. If Finder says an
   item named AirCard already exists, choose "Replace", not "Keep Both". Your
   cards, saved originals and skin library are kept either way.
   If you open AirCard straight from this window instead, it offers to move
   itself into Applications and to replace an older copy there.

2. FIRST LAUNCH
   This copy of AirCard is not notarised by Apple, so macOS stops it the
   first time you open it.

   On macOS 15 or later:
   - Open AirCard once. When macOS says it cannot be opened, click Done.
   - Open System Settings > Privacy & Security and scroll down to Security.
   - Next to the message about AirCard, click "Open Anyway" and confirm
     with your Mac password.

   On macOS 14: Control-click AirCard in Applications, choose Open, then
   click Open.

   If macOS says AirCard "is damaged", open Terminal and run:
     xattr -dr com.apple.quarantine /Applications/AirCard.app
   then open AirCard again.

3. WHAT AIRCARD NEEDS
   Apple Silicon or Intel Mac, macOS 14 or later. AirCard uses the Python 3
   that comes with Apple's Command Line Tools. If they are missing, AirCard
   says so and shows the one command that installs them.

4. HOW TO USE

   [Apple Wallet cards]
   - Connect the iPhone with a cable that carries data. Unlock it and tap
     Trust. If your Mac asks whether to allow the accessory, click Allow.
   - Click "Scan Cards". On the iPhone, double-click the Side button, pass
     Face ID, and tap the card. Each card you tap appears in the list.
   - Click "Read Original Designs" before changing anything. AirCard keeps a
     copy of each card as it is now, so you can put it back later.
   - Click a card to pick a picture, or open "Skin Library" to import a whole
     pack from a zip, a folder or a link. Frame it and click "Use This Design".
   - Click "Flash Skins". Then force-close Wallet on the iPhone, or restart
     the iPhone, to see the new look.

   [Passcode keypad]
   - Open the "Passcode (.passthm)" tab.
   - Drop in a .passthm, .passtheme or zip theme, or make your own.
   - Click "Flash Passcode Theme", then lock or restart the iPhone.

============================================================
Developed by @mak5er & @Lumid-Off
============================================================
