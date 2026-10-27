-- deepmud: load the GE extensions when the game starts.
-- modmanager runs every /scripts/**/modScript.lua at startup and wraps
-- extensions.load so the loaded extension stays across level changes
-- (lua/ge/extensions/core/modmanager.lua:695-711).
setExtensionUnloadMode('deepmud_main', 'manual')
setExtensionUnloadMode('deepmud_gui', 'manual')
extensions.load('deepmud_main')
extensions.load('deepmud_gui')
