$src = Get-Content /mnt/user-data/outputs/FocusedTweaks.ps1 -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
foreach ($n in 'ConvertFrom-RegHex','ConvertFrom-RegText') { . ([scriptblock]::Create(($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $n }, $true))[0].Extent.Text)) }
$t = @'
Windows Registry Editor Version 5.00

; Group A
[HKEY_CURRENT_USER\Software\Test]
"good"=dword:0000000a
"weird"=hex(9):01,02
"after"="ok \"quoted\" C:\\path"
"multi"=hex(7):61,00,00,00,62,00,00,00,00,00
"cont"=hex:01,02,\
  03,04
@="default"
"gone"=-

; Group B
[-HKEY_CURRENT_USER\Software\Gone]
'@
$ops = ConvertFrom-RegText -Text $t
"ops: $($ops.Count) (expected 7: good, after, multi, cont, default, gone, DeleteKey)"
$ops | % { "{0,-12} {1,-8} {2,-14} {3}" -f $_.Group, $_.Action, $_.Type, $(if ($_.Value -is [array]) { $_.Value -join ',' } else { "$($_.Name)=$($_.Value)" }) }
"unsupported type emitted with null Type: $(@($ops | ? { $_.Action -eq 'Set' -and -not $_.Type }).Count) (expected 0)"
