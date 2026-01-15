# Install OCI CLI

# Create Dynamic Group - Aligns instances to group

All {resource.type = 'instance', resource.compartment.id = 'ocid1.compartment.oc1..xxxxxxxx'}

# Create Dynamic Group Policy - Gives instances in group permissions to push to metrics to namespace

Allow dynamic-group Default/Production-Compute to use metrics in tenancy where target.metrics.namespace = 'production'

# Run disk_metrics.ps1

./disk_metrics.ps1

# Setup as a job

schtasks /Create /TN "OCI Disk Metrics" /SC MINUTE /MO 5 /RU "SYSTEM" /RL HIGHEST `/TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"C:\Users\opc\Desktop\disk_metrics.ps1`""

# Run now

schtasks /Run /TN "OCI Disk Metrics"

# Verify Runs

schtasks /Query /TN "OCI Disk Metrics" /V /FO LIST
