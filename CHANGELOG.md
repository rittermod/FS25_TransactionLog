# Changelog

All notable user-facing changes to FS25 Transaction Log are documented here.

2.0.0.0-dev.2:
- Multiplayer: players now see and export only their own farm's transaction log (view and export isolation).
- Server: automatic CSV exports are now split per farm - one file per farm each day/month/year, so no auto-export file mixes different farms' transactions.
- Multiplayer: only an admin can clear the transaction log now, and clearing wipes it for every player (handled on the server).
- Multiplayer: only a farm admin can change mod settings now; the change is saved on the server and applied to every player's settings menu.
- Multiplayer: farm managers can now add and edit transaction comments, and the change syncs to everyone on that farm.
- Multiplayer: Add Comment and Export are now shown only to farm managers (workers no longer see them).
- Added: Players not in a farm now see a "join a farm" hint in the log instead of an empty table.
- Fixed: mod settings are now saved to the correct folder; a misnamed settings file left by an earlier version is moved there automatically when you load, with no settings lost.

2.0.0.0-dev.1:
- Breaking change: Transaction logs from earlier versions are not carried over - the storage format changed for the 2.0 line.
- Improved: Transaction types and categories now display in your current game language, instead of the language they were recorded in.
- Changed: On first load after updating, your existing log is automatically exported to CSV and a fresh log is started (an on-screen message names the exported file).
- Changed: Each transaction now carries a stable internal id, so saved and exported logs keep their original capture order regardless of how the viewer is sorted (groundwork for multiplayer).
- Changed: Internal groundwork for multiplayer - balance capture, save/load, and settings persistence now run only on the game host/server. No change in singleplayer.
- Changed: Internal groundwork for multiplayer - added the network event layer that will carry transactions between host and clients. Not active yet; no change in singleplayer.
- Changed: Internal groundwork for multiplayer - the host now records every farm's transactions and delivers each new entry only to the farm it belongs to. Not active yet; no change in singleplayer.
- Changed: Internal groundwork for multiplayer - players joining or switching farms now receive a snapshot of their farm's transaction history, so each player's log matches their own farm. Not active yet; no change in singleplayer.

---

For release notes prior to 2.0.0.0, see the [GitHub releases page](https://github.com/rittermod/FS25_TransactionLog/releases).
