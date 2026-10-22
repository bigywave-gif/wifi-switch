Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "WinVer.nsh"
!ifndef VERSION
  !define VERSION "0.1.9"
!endif
!ifndef PAYLOAD
  !error "PAYLOAD must point to the verified Windows publish directory"
!endif
!ifndef OUTPUT
  !error "OUTPUT must specify the installer output file"
!endif
Name "WiFi Switch"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\WiFi Switch"
InstallDirRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WiFiSwitch" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "WiFi Switch · Windows"
VIProductVersion "0.1.9.0"
VIAddVersionKey "ProductName" "WiFi Switch"
VIAddVersionKey "FileDescription" "WiFi Switch Windows Installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "WiFi Switch"
!define MUI_ICON "../src/WiFiSwitch.Windows/Assets/app.ico"
!define MUI_UNICON "../src/WiFiSwitch.Windows/Assets/app.ico"
!define MUI_WELCOMEPAGE_TEXT "安装 WiFi Switch，并添加开始菜单入口。下一步可使用默认目录，也可选择其他安装目录。$\r$\n$\r$\n安装与升级不会读取密码、连接 Wi-Fi 或清空已有账号。$\r$\n$\r$\n请先从托盘齿轮菜单退出正在运行的 WiFi Switch。"
!insertmacro MUI_PAGE_WELCOME
!define MUI_DIRECTORYPAGE_TEXT_TOP "请选择 WiFi Switch 的安装目录。可保留默认路径，或点击“浏览”选择当前用户有写入权限的其他文件夹。$\r$\n$\r$\n账号和密码独立保存，不随程序安装目录移动。升级时默认使用上次安装目录。"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\WiFiSwitch.exe"
!define MUI_FINISHPAGE_RUN_NOTCHECKED
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\README.txt"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_ICONSTOP "需要 Windows 10 或 Windows 11。"
    Abort
  ${EndIf}
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "此安装包适用于 Intel/AMD 64 位 Windows。"
    Abort
  ${EndIf}
  SetShellVarContext current
  System::Call 'kernel32::OpenMutexW(i 0x100000, i 0, w "Local\WiFiSwitch.Windows") p.r0'
  ${If} $0 != 0
    System::Call 'kernel32::CloseHandle(p r0)'
    MessageBox MB_ICONEXCLAMATION "请先从 WiFi Switch 托盘齿轮菜单选择“退出系统”，再安装或升级。"
    Abort
  ${EndIf}
FunctionEnd

Section "WiFi Switch" Main
  SetOutPath "$INSTDIR"
  SetOverwrite on
  File "${PAYLOAD}/WiFiSwitch.exe"
  File "${PAYLOAD}/README.txt"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\WiFi Switch"
  CreateShortcut "$SMPROGRAMS\WiFi Switch\WiFi Switch.lnk" "$INSTDIR\WiFiSwitch.exe"
  CreateShortcut "$SMPROGRAMS\WiFi Switch\使用说明.lnk" "$INSTDIR\README.txt"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WiFiSwitch" "DisplayName" "WiFi Switch"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WiFiSwitch" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WiFiSwitch" "Publisher" "WiFi Switch"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WiFiSwitch" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WiFiSwitch" "DisplayIcon" "$INSTDIR\WiFiSwitch.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WiFiSwitch" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WiFiSwitch" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WiFiSwitch" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WiFiSwitch" "NoRepair" 1
SectionEnd

Function un.onInit
  SetShellVarContext current
  System::Call 'kernel32::OpenMutexW(i 0x100000, i 0, w "Local\WiFiSwitch.Windows") p.r0'
  ${If} $0 != 0
    System::Call 'kernel32::CloseHandle(p r0)'
    MessageBox MB_ICONEXCLAMATION "请先退出 WiFi Switch 再卸载。"
    Abort
  ${EndIf}
FunctionEnd

Section "Uninstall"
  Delete "$INSTDIR\WiFiSwitch.exe"
  Delete "$INSTDIR\README.txt"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\WiFi Switch\WiFi Switch.lnk"
  Delete "$SMPROGRAMS\WiFi Switch\使用说明.lnk"
  RMDir "$SMPROGRAMS\WiFi Switch"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WiFiSwitch"
  ; Preserve %LOCALAPPDATA%\WiFiSwitch, Credential Manager, and WLAN profiles.
SectionEnd
