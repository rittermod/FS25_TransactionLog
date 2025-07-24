# FS25_TransactionLog

For the micromanagers out there that want to keep track of their farm's transactions, 
this mod adds a transaction log to the game. 

**Singleplayer only.**

## Notes
Since there is no proper documentation for modding FS25 yet, this mod is made by trial and error and looking at other mods. It may not work as expected and could potentially cause issues with your game.

Default key binding is `Right Shift + T` to open the transaction log interface. You can change this in the game settings under "Controls".

Source code and issue tracker at https://github.com/rittermod/FS25_TransactionLog

## Features
 - **Transaction Logging**: Automatically tracks all financial transactions (income and expenses) in real-time
  - **Transaction combining**: Groups frequent small transactions (landscaping, fuel purchase etc) to reduce log clutter.
  - **GUI Interface**: View transaction history in an in-game dialog (accessible via RightShift+T)
  - **Transaction Details**: Display ingame date/time, transaction type, amount, and current farm balance
  - **Add Comments**: Edit and add custom comments to individual transactions
  - **Persistent Storage**: Automatically save and load transaction data with your savegame
  - **Export to CSV**: Export transaction history to CSV files in the mod settings directory for external analysis
  - **Clear Transaction Log**: Remove all stored transactions with confirmation dialog

## Installation
1. Download the latest release from the [GitHub releases page](https://github.com/rittermod/FS25_TransactionLog/releases/latest)
2. Move or copy the zip file into your Farming Simulator 2025 mods folder, typically located at:
   - Windows: `Documents/My Games/FarmingSimulator2025/mods`
   - macOS: `~/Library/Application Support/FarmingSimulator2025/mods`
3. Make sure you don't have any older versions of the mod installed in the mods folder


## Screenshots
Transaction log interface with a list of transactions, including date, type, amount, and comments.
![Transaction Log](screenshots/transaction_log.png)


