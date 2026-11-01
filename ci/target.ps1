# Another app's window behind the notch. It writes down the clicks and drops that really reach it.
# Pressing in its lower part starts dragging a file, the way Explorer would.
param([string]$Log, [string]$File, [switch]$Fullscreen)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$screen = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.BackColor = [Drawing.Color]::SteelBlue
$form.AllowDrop = $true
if ($Fullscreen) {
    $form.Bounds = $screen
} else {
    $form.Bounds = New-Object Drawing.Rectangle(([int]($screen.Width / 2) - 450), 0, 900, 500)
}

$form.Add_MouseDown({
    param($sender, $e)
    $at = $sender.PointToScreen($e.Location)
    Add-Content -Path $Log -Value "down $($at.X) $($at.Y)"
    if ($e.Y -gt 300 -and $File) {
        $data = New-Object Windows.Forms.DataObject
        $files = New-Object System.Collections.Specialized.StringCollection
        [void]$files.Add($File)
        $data.SetFileDropList($files)
        [void]$sender.DoDragDrop($data, [Windows.Forms.DragDropEffects]::Copy)
        Add-Content -Path $Log -Value 'drag over'
    }
})
$form.Add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent('FileDrop')) { $e.Effect = 'Copy' }
})
$form.Add_DragDrop({
    param($sender, $e)
    Add-Content -Path $Log -Value ('dropped ' + ($e.Data.GetData('FileDrop') -join ';'))
})

[Windows.Forms.Application]::Run($form)
