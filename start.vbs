' Chatik - launch without a console window
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
sh.CurrentDirectory = dir
cmd = """" & ps & """ -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\chatik.ps1"""
sh.Run cmd, 0, False
