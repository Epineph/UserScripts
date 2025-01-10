#!/bin/bash

# Function to print help text
help() {
  cat <<EOF
Usage: gpg_key.sh [OPTION]

Options:
  -k, --key-id        The id of the key (for signing or receiving). This argument is mandatory.
  -r, --recv-key      Receive the key (fetch key from a keyserver).
  -l, --lsign-key     Locally sign the key.
  -e, --encrypt       Encrypt a file symmetrically.
  -d, --decrypt       Decrypt a symmetrically encrypted file.
  -g, --gen-key       Generate a new GPG secret key.
  -x, --export-key    Export the GPG public key in GitHub-compatible format.
  -t, --file          Specify the file for encryption, decryption, or key export.
  -h, --help          Show this help message.

Examples:
  Encrypt a file symmetrically:
    gpg_key.sh --encrypt -t "myfile.txt"
    This will encrypt 'myfile.txt' using AES256 encryption.

  Decrypt a file symmetrically:
    gpg_key.sh --decrypt -t "myfile.txt.gpg"
    This will decrypt 'myfile.txt.gpg' back to 'myfile.txt.decrypted'.

  Generate a new GPG secret key:
    gpg_key.sh --gen-key
    This will guide you through generating a new key pair.

  Export a GPG public key for GitHub:
    gpg_key.sh --export-key -k "mykeyid"
    This will export the public key with the ID 'mykeyid' in a GitHub-compatible format.

  Receive a key from a keyserver:
    gpg_key.sh --recv-key -k "mykeyid"
    This will fetch the key with the ID 'mykeyid' from a keyserver.

  Locally sign a key:
    gpg_key.sh --lsign-key -k "mykeyid"
    This will locally sign the key with ID 'mykeyid'.

EOF
}

# Symmetric encryption function
encrypt_file() {
  local file="$1"
  echo "Encrypting file $file symmetrically..."
  gpg --symmetric --cipher-algo AES256 --output "$file.gpg" "$file"
  echo "Encryption complete. Output file: $file.gpg"
}

# Symmetric decryption function
decrypt_file() {
  local file="$1"
  echo "Decrypting file $file..."
  gpg --decrypt --output "$file.decrypted" "$file"
  echo "Decryption complete. Output file: $file.decrypted"
}

# Generate a new GPG key
generate_key() {
  echo "Generating a new GPG secret key..."
  gpg --full-generate-key
  echo "Key generation complete."
}

# Export the public key in GitHub-compatible format
export_key() {
  local key_id="$1"
  if [ -z "$key_id" ]; then
    echo "Error: Key ID is required for exporting the key."
    exit 1
  fi
  echo "Exporting public key $key_id in GitHub-compatible format..."
  gpg --armor --export "$key_id"
  echo "Export complete."
}

# Check if no arguments are passed
if (( $# == 0 )); then
  echo "error: No argument passed."
  help
  exit 1
fi

# Parse command-line options
while [ "$1" != "" ]; do
  case $1 in
    -k | --key-id)
      shift
      key_id="$1"
      ;;
    -r | --recv-key)
      if [ -z "$key_id" ]; then
        echo "Error: Key ID is required with -r option."
        exit 1
      fi
      revocation=$(gpg --recv-keys "$key_id")
      echo "Key $key_id received successfully."
      ;;
    -l | --lsign-key)
      if [ -z "$key_id" ]; then
        echo "Error: Key ID is required with -l option."
        exit 1
      fi
      sign_locally=$(gpg --lsign-key "$key_id")
      echo "Key $key_id locally signed."
      ;;
    -e | --encrypt)
      shift
      if [ -z "$1" ]; then
        echo "Error: No file specified for encryption."
        exit 1
      fi
      encrypt_file "$1"
      ;;
    -d | --decrypt)
      shift
      if [ -z "$1" ]; then
        echo "Error: No file specified for decryption."
        exit 1
      fi
      decrypt_file "$1"
      ;;
    -g | --gen-key)
      generate_key
      ;;
    -x | --export-key)
      shift
      if [ -z "$key_id" ]; then
        echo "Error: Key ID is required for exporting the key."
        exit 1
      fi
      export_key "$key_id"
      ;;
    -t | --file)
      shift
      file_path="$1"
      ;;
    -h | --help)
      help
      exit 0
      ;;
    *)
      echo "Error: Invalid option $1"
      help
      exit 1
      ;;
  esac
  shift
done
