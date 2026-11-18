; Risk of Rain 2 from Steam, installed as a standalone game copy.
; This is the 64-bit Unity build (Steam build 25921972).
; PW_PS4_POKE_REPEAT keeps the previously measured wait workaround enabled:
; it advanced startup from 2% to 26% on the Orbis-Win test runtime.

[application]
id = risk-of-rain-2
name = Risk of Rain 2
executable = C:\Games\RiskOfRain2\Risk of Rain 2.exe
working_directory = C:\Games\RiskOfRain2
prefix = risk-of-rain-2
runtime = wine-wow64
architecture = pe64
graphics = dxvk
dll_overrides = d3d8,d3d9,d3d10core,d3d11,dxgi=n

[display]
desktop = 1920x1080
scaling = fit

[input]
mode = xinput

[debug]
env = PW_PS4_POKE_REPEAT=1
