@echo off
setlocal
cd /d "%~dp0"
echo.
echo MKV Extract Enhanced 1.0
echo ============================
python -c "import struct,sys; print('Python:',sys.executable); print('Architecture:',struct.calcsize('P')*8,'-bit'); sys.exit(0 if struct.calcsize('P')*8==64 else 1)"
if errorlevel 1 goto BADPY
python -m PyInstaller --version >nul 2>&1
if errorlevel 1 goto NOPYI
echo.
echo Building 64-bit onedir version...
python -m PyInstaller --noconfirm --clean "../src/MKV_Extract_Enhanced_1.0.spec"
if errorlevel 1 goto BUILDFAIL
echo.
echo BUILD SUCCESS
pause
exit /b 0
:BADPY
echo ERROR: 64-bit Python is required.
pause
exit /b 1
:NOPYI
echo ERROR: PyInstaller not found.
echo Run: python -m pip install pyinstaller
pause
exit /b 1
:BUILDFAIL
echo ERROR: PyInstaller build failed.
pause
exit /b 1
