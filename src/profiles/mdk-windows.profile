; MDK Glide/3Dfx version, imported from the official MDK 1.1 patch.
[application]
id = mdk-windows
name = MDK (Windows)
executable = C:\SHINY\MDK\MDK3DFX.exe
working_directory = C:\SHINY\MDK
dll_overrides = d3d8,d3d9,d3d10core,d3d11,dxgi=n
prefix = mdk-windows
runtime = wine-wow64
architecture = pe32
graphics = dxvk

[display]
desktop = 1920x1080
scaling = fit
view = window

[runtime]
; Keep the failed-path CPU mode fixed while validating the selector correction.
cpu = translator

[debug]
winedebug = +fps,+loaddll,+seh

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
