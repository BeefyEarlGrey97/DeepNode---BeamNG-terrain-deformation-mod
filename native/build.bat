@echo off
rem Builds native\out\mswsock.dll (x64). Install: copy it to <game>\Bin64, restart the game.
rem Uninstall: delete <game>\Bin64\mswsock.dll.
setlocal
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`call "%VSWHERE%" -latest -products * -property installationPath`) do set "VS=%%i"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%~dp0"
if not exist out mkdir out
cl /nologo /O2 /W4 /LD /MT dnnative.c /Feout\mswsock.dll /Foout\ /link ws2_32.lib || exit /b 1
cl /nologo /W4 /MT test_load.c /Feout\test_load.exe /Foout\ || exit /b 1
