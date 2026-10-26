param([string]$Name = 'A')
Add-Type -AssemblyName System.Windows.Forms
$form = New-Object Windows.Forms.Form
$form.Text = "Caelestia Tiling Test $Name"
$form.StartPosition = 'Manual'
$form.Location = New-Object Drawing.Point(200, 200)
$form.Size = New-Object Drawing.Size(600, 400)
[void]$form.ShowDialog()
