; Vampire: The Masquerade - Bloodlines (GOG)
; Native WoW64, 1080p registry mode, DualSense mapped to manual PC controls.
[application]
id = bloodlines-gog
name = Vampire: The Masquerade - Bloodlines (GOG)
executable = C:\Games\Bloodlines\vampire.exe
working_directory = C:\Games\Bloodlines
dll_overrides = d3d8,d3d9,d3d10core,d3d11,dxgi=n
prefix = bloodlines-gog
runtime = wine-wow64
architecture = pe32
graphics = dxvk

[display]
desktop = 1920x1080
scaling = fit
menu = true

[input]
mode = keyboard
mouse = right_stick
mouse_speed = 1200
keyboard_stick = left_stick
stick_deadzone = 25
cross = mouse_left
circle = ctrl
square = r
triangle = z
l1 = mouse_right
r1 = mouse_left
l2 = f
r2 = e
l3 = tab
r3 = none
up = up
down = down
left = left
right = right
options = escape
create = enter

[runtime]
cpu = native
