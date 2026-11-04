; MDK Direct3D version, staged from $GAME_SOURCE/games/MDK Final/SHINY/MDK.
[application]
id = mdk
name = MDK
executable = C:\SHINY\MDK\MDKD3D.EXE
working_directory = C:\SHINY\MDK
dll_overrides = d3d9=b;dxgi=b
prefix = mdk
runtime = wine-wow64
architecture = pe32
graphics = dxvk

[display]
desktop = 1920x1080
view = window

[input]
; MDK's documented keyboard defaults; left stick emits arrow keys for movement.
mode = keyboard
mouse = none
keyboard_stick = left_stick
stick_deadzone = 25
stick_up = up
stick_down = down
stick_left = left
stick_right = right
cross = enter
circle = escape
square = ctrl
triangle = space
up = up
down = down
left = left
right = right
l1 = alt
r1 = shift
l2 = a
r2 = z
options = f12

[runtime]
; Keep translator selected for this DLL-load comparison; change only d3d9.
cpu = translator

[debug]
winedebug = +fps,+loaddll
