; Half-Life Game of the Year Edition with Opposing Force

[application]
id = half-life
name = Half-Life (GOTY + Opposing Force)
executable = C:\Sierra\Half-Life\hl.exe
working_directory = C:\Sierra\Half-Life
; As upstream prospero-win-profiles: windowed at the native 1920x1080 (no fullscreen mode switch,
; which spawned extra Zink swapchains that found the display busy), OpenGL via Zink (2026-11-05).
arguments = -game valve -window -w 1920 -h 1080 -gl
prefix = half-life
runtime = wine-wow64
architecture = pe32
graphics = opengl

[display]
desktop = 1920x1080
scaling = fit

[input]
preset = goldsrc

