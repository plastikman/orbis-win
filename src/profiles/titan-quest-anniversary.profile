; Titan Quest Anniversary — DX11 A/B with PS4 controller mouse bindings.

[application]
id = titan-quest-anniversary
name = Titan Quest Anniversary
executable = C:\Games\TitanQuestAE\TQ.exe
working_directory = C:\Games\TitanQuestAE
dll_overrides = d3d8,d3d9,d3d10core,d3d11,dxgi=n
prefix = titan-quest-anniversary
runtime = wine-wow64
architecture = pe32
graphics = dxvk
arguments = /dx11 thqno_overlay_disabled

[display]
desktop = 1920x1080
scaling = fit
show_fps = false

[input]
mode = keyboard
mouse = left_stick
mouse_speed = 1200
cross = mouse_left
circle = mouse_right
r1 = mouse_left

[runtime]
cpu = native

[debug]
winedebug = err+ntdll,warn+vulkan
