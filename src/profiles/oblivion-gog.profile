; Oblivion's PS3-style DualSense mapping translated to PC keyboard/mouse
; actions. Joystick input stays disabled in Oblivion.ini; controller buttons
; emit the corresponding PC keyboard or mouse actions.
[application]
id = oblivion-gog
name = The Elder Scrolls IV: Oblivion (GOG)
executable = C:\Games\OblivionGOG\Oblivion.exe
working_directory = C:\Games\OblivionGOG
prefix = oblivion-gog
runtime = wine-wow64
architecture = pe32
graphics = dxvk

[display]
desktop = 1920x1080
view = window

[input]
mode = keyboard
mouse = right_stick
mouse_speed = 1200
keyboard_stick = left_stick
stick_deadzone = 25
; PS3 actions translated to Oblivion's PC defaults.
cross = space
circle = tab
square = f
triangle = e
l1 = alt
r1 = mouse_left
l2 = z
r2 = c
l3 = ctrl
r3 = r
up = up
down = down
left = left
right = right
options = escape
create = t

[debug]
winedebug = +ps5drv,warn+dinput,warn+rawinput,warn+msg,warn+vulkan,+seh
