setExtensionUnloadMode("rainPuddles", "manual")
setExtensionUnloadMode("rainPuddlesWet", "manual")
setExtensionUnloadMode("rainPuddlesHydro", "manual")   -- 1.1: loaded by rainPuddles; set here as the game asks
setExtensionUnloadMode("rainPuddlesAudio", "manual")   -- 1.6 rain sound: loaded by rainPuddles
extensions.load("rainPuddlesWet")
extensions.load("rainPuddles")
-- 1.0.2: the BeamNG.Earth bridge (does nothing on other maps or without BeamNG.Earth)
setExtensionUnloadMode("rainPuddlesEarth", "manual")
extensions.load("rainPuddlesEarth")
