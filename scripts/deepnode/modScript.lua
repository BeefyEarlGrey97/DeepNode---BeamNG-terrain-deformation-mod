-- deepnode: load the GE extensions when the game starts.
-- modmanager runs every /scripts/**/modScript.lua at startup and wraps
-- extensions.load so the loaded extension stays across level changes
-- (lua/ge/extensions/core/modmanager.lua:695-711).
setExtensionUnloadMode('deepnode_main', 'manual')
setExtensionUnloadMode('deepnode_gui', 'manual')
extensions.load('deepnode_main')
extensions.load('deepnode_gui')
