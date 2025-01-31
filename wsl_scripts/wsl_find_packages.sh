###
#!/bin/bash

# Help Section
cat << EOF
SYNOPSIS
    Executes PowerShell's Find-Package cmdlet from WSL and exports the results to a CSV file.

DESCRIPTION
    This script uses PowerShell to execute the Find-Package cmdlet on a Windows host from WSL. The results
    are exported to a CSV file for use in tools like Excel or RStudio. The script supports filtering packages
    by name or pattern, limiting the number of results, and sorting by specific properties.

USAGE
    ./find_packages.sh [OPTIONS]

OPTIONS
    --output-path <path>    Specify the output file path for the CSV. Defaults to /mnt/c/Packages.csv.
    --delimiter <char>      Specify the delimiter for the CSV file. Defaults to ','.
    --name-filter <pattern> Filter packages by name or wildcard pattern (e.g., 'az*'). Defaults to '*'.
    --max-results <number>  Limit the number of results. Defaults to unlimited.
    --order-by <property>   Specify the property to sort results by (e.g., 'Name', 'Popularity'). Defaults to 'Name'.
    --help                  Display this help message.

EXAMPLES
    ./find_packages.sh --output-path /mnt/c/MyPackages.csv --delimiter ';' --name-filter 'az*' --max-results 10 --order-by 'Popularity'
        Exports up to 10 packages matching the pattern 'az*', sorted by popularity, to a semicolon-separated CSV file.

    ./find_packages.sh
        Exports all packages to a default location (/mnt/c/Packages.csv) using a comma as the delimiter and sorted by name.
EOF

# Default values
OUTPUT_PATH="/mnt/c/Packages.csv"
DELIMITER=","  
NAME_FILTER="*"
MAX_RESULTS=""
ORDER_BY="Name"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --output-path)
            OUTPUT_PATH="$2"
            shift
            shift
            ;;
        --delimiter)
            DELIMITER="$2"
            shift
            shift
            ;;
        --name-filter)
            NAME_FILTER="$2"
            shift
            shift
            ;;
        --max-results)
            MAX_RESULTS="$2"
            shift
            shift
            ;;
        --order-by)
            ORDER_BY="$2"
            shift
            shift
            ;;
        --help)
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Construct PowerShell command
PS_COMMAND="Find-Package -Name '$NAME_FILTER'"
if [[ -n "$MAX_RESULTS" ]]; then
    PS_COMMAND+=" | Select-Object -First $MAX_RESULTS"
fi
if [[ -n "$ORDER_BY" ]]; then
    PS_COMMAND+=" | Sort-Object -Property $ORDER_BY"
fi
PS_COMMAND+=" | Export-Csv -Path \"$OUTPUT_PATH\" -Delimiter '$DELIMITER' -NoTypeInformation"

# Execute PowerShell command
powershell.exe -Command "$PS_COMMAND"

if [[ $? -eq 0 ]]; then
    echo "Packages exported successfully to $OUTPUT_PATH."
else
    echo "An error occurred during execution."
    exit 1
fi
