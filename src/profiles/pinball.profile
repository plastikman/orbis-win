; Space Cadet Pinball: simple GDI/WinMM baseline for the PS4 Wine port.
; Source files: $GAME_SOURCE/games/pinball. Keep it in a separate prefix.
[application]
id = pinball
name = Space Cadet Pinball
executable = C:\Games\Pinball\Pinball.exe
working_directory = C:\Games\Pinball
prefix = pinball
runtime = wine-wow64
architecture = pe32
graphics = gdi

[display]
desktop = 800x600
; Show the surrounding desktop rather than cropping to the game window.
view = desktop

[input]
mode = keyboard
cross = space
l1 = z
r1 = slash
options = f2

[runtime]
cpu = translator

[debug]
winedebug = +tid,err+all,warn+font,+win,+keyboard,+key,+ps5drv
