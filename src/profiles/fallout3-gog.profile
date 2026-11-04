; GOG Fallout 3 GOTY, installed from the offline 1.7.0.3 installer.
; Start the game executable directly; the launcher is not required.
[application]
id = fallout3-gog
name = Fallout 3 GOTY (GOG)
executable = C:\Games\Fallout3\Fallout3.exe
working_directory = C:\Games\Fallout3
dll_overrides = d3d9=n;dxgi=b
prefix = fallout3-gog
runtime = wine-wow64
architecture = pe32
graphics = dxvk

[display]
desktop = 1920x1080
scaling = fit

[input]
mode = xinput

[runtime]
cpu = native
