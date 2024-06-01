#!/bin/bash

# locate at e.g., /usr/bin or someone else included in the environment variable "$PATH" to be able to execute as a script.

# Help information
show_help() {
    cat << EOF
Usage: $(basename "$0") [path] [OPTIONS]...
Change ownership and/or permissions of a given file or directory.

Arguments:
  path                  Specify the path to the file or directory.

Options:
  --help                Show this help message and exit.
  -R                    Apply changes recursively. You will be prompted for confirmation.
  ownership [username]  Change the ownership. Use "activeuser" to set to the current user.
  permissions [perms]   Set permissions in numeric (octal) or symbolic format.

Examples:
  $(basename "$0") /path/to/file # shows current ownership and permissions
  $(basename "$0") /path/to/file ownership # shows current ownership
  $(basename "$0") /path/to/dir permissions 755
  $(basename "$0") /path/to/dir -R permissions u=rwx,g=rx,o=rx
  $(basename "$0") /path/to/dir ownership root permissions rwx---r-- (704/u=rwx,o=r)
EOF
}

noconfirm=false
recurse=false
force_recurse=false

# Recursive operation confirmation
# Function for recursive operation confirmation
recursive_change_confirmation() {
    if ! $noconfirm && ! $force_recurse; then
        echo "You have requested a recursive operation. This action may modify permissions for a large number of files and can break your system if not used carefully."
        echo -n "Are you sure you want to continue with this recursive change? [y/N]: "
        read response
        if [[ "$response" != "y" ]]; then
            echo "Recursive change cancelled."
            exit 1
        fi
    fi
}

calculate_numeric_perm() {
    local perm_section=$1  # e.g., "rwx"
    local -n num_val_ref=$2  # Reference for the result
    local -i result=0
    
    [[ $perm_section == *r* ]] && ((result += 4))
    [[ $perm_section == *w* ]] && ((result += 2))
    [[ $perm_section == *x* ]] && ((result += 1))
    
    num_val_ref=$result
}


# Pre-process arguments for --noconfirm
for arg; do
    case "$arg" in
        --noconfirm)
            noconfirm=true
            ;;
        --recursively-apply|--recurse-action)
            recurse=true
            ;;
        --force-recursively|--recursively-force)
            force_recurse=true
            recurse=true  # Imply recursion
            ;;
    esac
done

# Main script functionality
main() {
    local processed_args=()
    local target
    local recursive=""
    local operation_set=false
    local last_operation=""

    # Rebuild argument list without --noconfirm (if present)
    for arg in "$@"; do
        if [[ $arg != "--noconfirm" ]]; then
            processed_args+=("$arg")
        fi
    done

    # Now work with processed_args instead of $@
    set -- "${processed_args[@]}"

    if [[ -z $1 || $1 == "--help" ]]; then
        show_help
        exit 0
    fi
    target="$1"; shift

    # Main argument processing loop
    while [[ $# -gt 0 ]]; do
    # Convert to lowercase for case-insensitive comparison
    option=$(echo "$1" | tr '[:upper:]' '[:lower:]')
        case "$1" in
            -r|-R|--recursive)
                recursive="-R"
                shift
                recursive_change_confirmation
                ;;
            -c|--current-owner|currentowner|currentownership)
                echo "Current ownership of $target:"
                # Fetch and display owner and group
                local owner=$(stat -c %U "$target")
                local group=$(stat -c %G "$target")
                echo "Owner: $owner, Group: $group"
                operation_set=true
                shift
                ;;
            -a|--active-permissions|--active-perms|currentperms)
                echo "Current permissions of $target:"
                # Fetch and display permissions in symbolic and numeric formats
                local symbolic_perms=$(stat -c %A "$target")
                local numeric_perms=$(stat -c %a "$target")
                # Extract user, group, and others permissions for symbolic display
                local user_perms=$(echo $symbolic_perms | cut -c 2-4)
                local group_perms=$(echo $symbolic_perms | cut -c 5-7)
                local others_perms=$(echo $symbolic_perms | cut -c 8-10)
                echo "Symbolic: $symbolic_perms, Numeric: $numeric_perms"
                echo "Detailed: u=${user_perms},g=${group_perms},o=${others_perms}"
                operation_set=true
                shift
                ;;
            -o|--owner|ownership|owner)
                echo "Changing ownership of $target to $2..."
                chown $recursive $2 "$target"
                echo "Ownership change completed."
                operation_set=true
                shift 2
                ;;
            -p|--perm|--perms|--permission|--perm|permissions|perms|perm)
                shift
                local perms="$1"
                local perm_val=""
                shift # Ensure the permission value is consumed and not re-evaluated

                # Conditional checks for permission format
                if [[ $perms =~ ^[0-7]{3}$ ]]; then
                    perm_val="$perms"
                elif [[ $perms =~ ^[rwx-]{9}$ ]]; then
                    # Symbolic to numeric conversion logic
                    perm_val=$(echo "$perms" | awk '{
    gsub("r", "4"); gsub("w", "2"); gsub("x", "1"); gsub("-", "0");
    sum = 0;
    sum += substr($0,1,1) * 64;
    sum += substr($0,2,1) * 64;
    sum += substr($0,3,1) * 64;
    sum += substr($0,4,1) * 8;
    sum += substr($0,5,1) * 8;
    sum += substr($0,6,1) * 8;
    sum += substr($0,7,1);
    sum += substr($0,8,1);
    sum += substr($0,9,1);
    printf "%o", sum;
}')
                elif [[ $perms =~ u=([rwx-]{1,3}),g=([rwx-]{1,3}),o=([rwx-]{1,3}) ]]; then
                    # Detailed format logic
                    local u_val=0 g_val=0 o_val=0
                    calculate_numeric_perm "${BASH_REMATCH[1]}" u_val
                    calculate_numeric_perm "${BASH_REMATCH[2]}" g_val
                    calculate_numeric_perm "${BASH_REMATCH[3]}" o_val
                    perm_val=$(printf '%o' "$((u_val*64 + g_val*8 + o_val))")
                else
                    echo "Invalid permissions format: $perms"
                    return 1
                fi

                echo "Setting permissions of $target to $perms..."
                chmod $recursive "$perm_val" "$target"
                echo "Permissions change applied successfully."
                display_current_permissions "$target" # Display updated permissions
                return 0 # Successfully handled the permissions, so return successfully
                ;;
            *)
                echo "Invalid option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    if [[ $operation_set == true ]]; then
        case "$last_operation" in
            currentownership)
                display_current_ownership "$target"
                ;;
            currentpermissions)
                display_current_permissions "$target"
                ;;
        esac
    else
        # Default behavior when no operation is specified
        echo "No specific operation requested. Displaying current ownership and permissions for: $target"
        display_current_ownership "$target"
        display_current_permissions "$target"
    fi
}

display_current_ownership() {
    local target=$1
    echo "Current ownership of $target:"
    local owner=$(stat -c %U "$target")
    local group=$(stat -c %G "$target")
    echo "Owner: $owner, Group: $group"
}

display_current_permissions() {
    local target=$1
    echo "Current permissions of $target:"
    local symbolic_perms=$(stat -c %A "$target")
    local numeric_perms=$(stat -c %a "$target")
    echo "Symbolic: $symbolic_perms, Numeric: $numeric_perms"
    local user_perms=$(echo $symbolic_perms | cut -c 2-4)
    local group_perms=$(echo $symbolic_perms | cut -c 5-7)
    local others_perms=$(echo $symbolic_perms | cut -c 8-10)
    echo "Detailed: u=${user_perms},g=${group_perms},o=${others_perms}"
}

main "$@"


