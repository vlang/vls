@echo off
echo Building vls...

if "%~1" == "-msvc" (
	v -gc boehm -cc msvc cmd/vls -o vls.exe
	if %ERRORLEVEL% NEQ 0 goto :build_error
	goto :build_success
)

v -gc boehm -cc gcc cmd/vls -o vls.exe
if %ERRORLEVEL% NEQ 0 goto :build_error
goto :build_success

:build_error
echo.
echo Exiting from error
exit /b 1

:build_success
echo ^> VLS built successfully!
