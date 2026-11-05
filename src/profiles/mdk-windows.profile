; MDK 1.1 Direct3D clean install, using the local dgVoodoo DirectDraw wrapper.
[application]
id = mdk-windows
name = MDK (Windows)
executable = C:\SHINY\MDK\MDKD3D.exe
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
; Translator: native WoW64 still faults at GetStdHandle (FS base; HANDOFF-2026-11-03).
; Passed on GLDS10043 01.06/01.07 (2026-11-05). The prefix's Wow64\x86 key must
; name wowprospero.dll until the launcher selects it explicitly.
cpu = translator

[debug]
winedebug = +fps,+loaddll,+seh

[input]
; MDK's documented keyboard defaults; left stick emits arrow keys for movement.
mode = keyboard
mouse = right_stick
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
