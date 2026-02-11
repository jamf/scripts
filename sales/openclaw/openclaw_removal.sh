#!/bin/bash

###########################################################################################################################
#
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
#
###########################################################################################################################

################################################################################
# Removes OpenClaw on macOS including:
# - Running processes and gateway service
# - LaunchAgent services (current and legacy naming)
# - CLI binaries (npm/pnpm/bun installations)
# - macOS companion app
# - Docker containers, images, and compose stacks
# - Configuration directories and credentials
# - Legacy installations (Clawdbot, Moltbot)
#
# Usage:
#   ./openclaw_removal.sh                  # Remove for current user
#   sudo ./openclaw_removal.sh --all       # Remove for all users
#   ./openclaw_removal.sh --dry-run        # Preview what would be removed
#
# Options:
#   --all              Remove for all users (requires sudo)
#   --dry-run          Show what would be removed without removing
#   --no-backup        Skip creating backups of config directories
#   --keep-workspace   Preserve workspace directories
#   --docker-only      Only remove Docker containers/images
#   --help             Show this help message
#
# IMPORTANT: OAuth tokens persist on provider servers after local removal.
# After running this script, manually revoke these tokens to fully secure accounts:
#
#   Google/Gmail:     https://myaccount.google.com/permissions
#   Slack:            https://[workspace].slack.com/apps/manage
#   Discord:          User Settings > Authorized Apps
#   Microsoft:        https://account.microsoft.com/privacy/app-access
#   Telegram:         Chat with @BotFather, use /revoke
#   GitHub:           Settings > Developer settings > Personal access tokens
#
#   API Keys to rotate:
#     Anthropic:      https://console.anthropic.com/settings/keys
#     OpenAI:         https://platform.openai.com/api-keys
#     Google AI:      https://aistudio.google.com/app/apikey
#
#   Look for entries named OpenClaw, Moltbot, or Clawdbot.
################################################################################

set -euo pipefail

# Flags
DRY_RUN=false
ALL_USERS=false
NO_BACKUP=false
KEEP_WORKSPACE=false
DOCKER_ONLY=false

# Counters
ITEMS_REMOVED=0
ITEMS_FAILED=0

# Known identifiers
PROCESS_NAMES=("openclaw" "moltbot" "clawdbot" "clawd")
CONFIG_DIRS=(".openclaw" ".moltbot" ".clawdbot" ".molthub")
AGENT_PATTERNS=("bot.molt.*.plist" "com.openclaw.*.plist" "com.clawdbot.*.plist" "ai.openclaw.*.plist")

# Parse arguments
while [[ $# -gt 0 ]]; do
	case $1 in
		--dry-run)       DRY_RUN=true;       shift ;;
		--all)           ALL_USERS=true;      shift ;;
		--no-backup)     NO_BACKUP=true;      shift ;;
		--keep-workspace) KEEP_WORKSPACE=true; shift ;;
		--docker-only)   DOCKER_ONLY=true;    shift ;;
		--help)
			sed -n '/^# Usage:/,/^#####/{ /^####/d; s/^# \?//; p }' "$0"
			exit 0
			;;
		*)
			echo "Unknown option: $1 (try --help)"
			exit 1
			;;
	esac
done

################################################################################
# Utility functions
################################################################################

command_exists() { command -v "$1" >/dev/null 2>&1; }


remove_file() {
	local filepath="$1" label="$2"
	[[ ! -f "$filepath" ]] && return 0
	if [[ "$DRY_RUN" == true ]]; then
		echo "  [DRY RUN] Would remove file: $label"
	else
		if rm -f "$filepath" 2>/dev/null; then
			echo "  Removed: $label"
			((ITEMS_REMOVED++))
		else
			echo "  ! Failed to remove: $label"
			((ITEMS_FAILED++))
		fi
	fi
}

remove_directory() {
	local dirpath="$1" label="$2"
	[[ ! -d "$dirpath" ]] && return 0
	if [[ "$DRY_RUN" == true ]]; then
		echo "  [DRY RUN] Would remove directory: $label"
	else
		if rm -rf "$dirpath" 2>/dev/null; then
			echo "  Removed: $label"
			((ITEMS_REMOVED++))
		else
			echo "  ! Failed to remove: $label"
			((ITEMS_FAILED++))
		fi
	fi
}

################################################################################
# Process cleanup
################################################################################

kill_openclaw_processes() {
	echo ""
	echo "Stopping OpenClaw processes..."

	for name in "${PROCESS_NAMES[@]}"; do
		if pgrep -f "$name" >/dev/null 2>&1; then
			if [[ "$DRY_RUN" == true ]]; then
				echo "  [DRY RUN] Would kill $name processes"
			else
				pkill -9 -f "$name" 2>/dev/null || true
				echo "  Killed: $name"
				((ITEMS_REMOVED++))
			fi
		fi
	done

	# Node processes running openclaw specifically
	if pgrep -f "node.*openclaw" >/dev/null 2>&1; then
		if [[ "$DRY_RUN" == true ]]; then
			echo "  [DRY RUN] Would kill Node.js openclaw processes"
		else
			pkill -9 -f "node.*openclaw" 2>/dev/null || true
			echo "  Killed: node openclaw processes"
			((ITEMS_REMOVED++))
		fi
	fi

	# Wait for all OpenClaw processes to fully terminate
	if [[ "$DRY_RUN" == false ]]; then
		local _
		for _ in 1 2 3 4 5; do
			pgrep -f "openclaw|moltbot|clawdbot" >/dev/null 2>&1 || break
			sleep 0.5
		done
	fi
}

################################################################################
# LaunchAgent removal
################################################################################

remove_launch_agents() {
	local user_home="$1" username="$2"
	local launch_agents_dir="${user_home}/Library/LaunchAgents"
	local found_agents=false

	local uid
	uid=$(id -u "$username" 2>/dev/null || echo "")

	if [[ -z "$uid" ]]; then
		echo "  ! Could not resolve UID for $username, skipping LaunchAgent removal"
		return 0
	fi

	local gui_domain="gui/${uid}"

	# Plist files on disk — use plist-path bootout for full deregistration
	if [[ -d "$launch_agents_dir" ]]; then
		for pattern in "${AGENT_PATTERNS[@]}"; do
			for agent_file in "${launch_agents_dir}"/${pattern}; do
				[[ ! -f "$agent_file" ]] && continue
				found_agents=true

				local agent_name
				agent_name=$(basename "$agent_file" .plist)
				local service_target="${gui_domain}/${agent_name}"

				if [[ "$DRY_RUN" == true ]]; then
					echo "  [DRY RUN] Would unload and remove: $agent_name ($username)"
					continue
				fi

				# 1. Bootout first (unloads the service from launchd)
				launchctl bootout "$gui_domain" "$agent_file" 2>/dev/null || \
					launchctl bootout "$service_target" 2>/dev/null || true

				# 2. Disable to prevent reload on next boot
				launchctl disable "$service_target" 2>/dev/null || true

				# 3. Remove the plist file from disk
				remove_file "$agent_file" "LaunchAgent $agent_name ($username)"
			done
		done
	fi

	# Orphaned registrations — agent still in launchd but plist already gone from disk
	local label_prefixes=("bot.molt." "com.openclaw." "com.clawdbot." "ai.openclaw.")
	local registered_labels
	registered_labels=$(launchctl list 2>/dev/null | awk '{print $3}') || true

	for prefix in "${label_prefixes[@]}"; do
		while IFS= read -r agent_name; do
			[[ -z "$agent_name" ]] && continue
			found_agents=true
			local service_target="${gui_domain}/${agent_name}"

			if [[ "$DRY_RUN" == true ]]; then
				echo "  [DRY RUN] Would deregister orphaned agent: $agent_name ($username)"
				continue
			fi

			launchctl disable "$service_target" 2>/dev/null || true
			launchctl bootout "$service_target" 2>/dev/null || true

			echo "  Deregistered orphaned agent: $agent_name ($username)"
		done <<< "$(echo "$registered_labels" | grep "^${prefix}" || true)"
	done

	# Wait for launchd to fully process all deregistrations
	if [[ "$found_agents" == true ]] && [[ "$DRY_RUN" == false ]]; then
		sleep 5  # Give launchd adequate time to fully deregister

		# Final verification with retry
		for prefix in "${label_prefixes[@]}"; do
			local remaining
			remaining=$(launchctl list 2>/dev/null | awk '{print $3}' | grep "^${prefix}" || true)
			if [[ -n "$remaining" ]]; then
				echo "  ! Still registered after bootout: $remaining"
				# Try one more forceful removal
				while IFS= read -r stuck_agent; do
					[[ -z "$stuck_agent" ]] && continue
					local stuck_target="${gui_domain}/${stuck_agent}"
					launchctl kill SIGKILL "$stuck_target" 2>/dev/null || true
					launchctl bootout "$stuck_target" 2>/dev/null || true
					echo "  Attempted force removal: $stuck_agent"
				done <<< "$remaining"
			fi
		done
	fi
}

################################################################################
# Config directory backup and removal
################################################################################

remove_config_directories() {
	local user_home="$1" username="$2" backup_dir="$3"

	for dir_name in "${CONFIG_DIRS[@]}"; do
		local full_path="${user_home}/${dir_name}"
		[[ ! -d "$full_path" ]] && continue

		# Backup if enabled
		if [[ -n "$backup_dir" ]] && [[ "$NO_BACKUP" == false ]] && [[ "$DRY_RUN" == false ]]; then
			cp -R "$full_path" "${backup_dir}/${username}_${dir_name}" 2>/dev/null \
				&& echo "  Backed up: $dir_name ($username)" \
				|| echo "  ! Backup failed: $dir_name ($username)"
		fi

		# Preserve workspace if requested
		if [[ "$KEEP_WORKSPACE" == true ]] && [[ -d "${full_path}/workspace" ]]; then
			local ws_backup="${user_home}/${dir_name}_workspace_preserved"
			if [[ "$DRY_RUN" == false ]]; then
				cp -R "${full_path}/workspace" "$ws_backup" 2>/dev/null || true
				echo "  Workspace preserved: $ws_backup"
			else
				echo "  [DRY RUN] Would preserve workspace to: $ws_backup"
			fi
		fi

		remove_directory "$full_path" "$dir_name ($username)"
	done

	# Standalone workspace directory (Docker-style installs)
	if [[ -d "${user_home}/openclaw" ]]; then
		if [[ "$KEEP_WORKSPACE" == true ]]; then
			echo "  Keeping workspace: ${user_home}/openclaw (--keep-workspace)"
		else
			remove_directory "${user_home}/openclaw" "openclaw workspace ($username)"
		fi
	fi
}


################################################################################
# macOS app removal
################################################################################

remove_macos_app() {
	local user_home="$1" username="$2"

	# Per-user Applications folder
	remove_directory "${user_home}/Applications/OpenClaw.app" "OpenClaw.app ($username)"
}

################################################################################
# Per-user orchestration
################################################################################

remove_for_user() {
	local user_home="$1" username="$2" backup_dir="${3:-}"

	echo ""
	echo "Processing user: $username ($user_home)"

	# 1. Remove LaunchAgents (processes already killed globally in main)
	remove_launch_agents "$user_home" "$username"

	# 2. Remove config directories AFTER LaunchAgent is gone
	remove_config_directories "$user_home" "$username" "$backup_dir"

	# 3. Remove app bundle
	remove_macos_app "$user_home" "$username"
}

################################################################################
# Package manager removal
################################################################################

remove_package_managers() {
	echo ""
	echo "Removing global package installations..."

	# npm
	if command_exists npm; then
		local npm_prefix
		npm_prefix=$(npm prefix -g 2>/dev/null || echo "")
		if [[ -n "$npm_prefix" ]] && [[ -f "${npm_prefix}/bin/openclaw" ]]; then
			if [[ "$DRY_RUN" == true ]]; then
				echo "  [DRY RUN] Would run: npm rm -g openclaw"
			else
				if npm rm -g openclaw 2>/dev/null; then
					echo "  Removed: npm global openclaw"
					((ITEMS_REMOVED++)) || true
				else
					echo "  ! npm removal failed"
					((ITEMS_FAILED++)) || true
				fi
			fi
		fi
	fi

	# pnpm
	if command_exists pnpm; then
		if pnpm list -g 2>/dev/null | grep -q openclaw; then
			if [[ "$DRY_RUN" == true ]]; then
				echo "  [DRY RUN] Would run: pnpm remove -g openclaw"
			else
				if pnpm remove -g openclaw 2>/dev/null; then
					echo "  Removed: pnpm global openclaw"
					((ITEMS_REMOVED++)) || true
				else
					echo "  ! pnpm removal failed"
					((ITEMS_FAILED++)) || true
				fi
			fi
		fi
	fi

	# bun
	if command_exists bun; then
		if bun pm ls -g 2>/dev/null | grep -q openclaw; then
			if [[ "$DRY_RUN" == true ]]; then
				echo "  [DRY RUN] Would run: bun remove -g openclaw"
			else
				if bun remove -g openclaw 2>/dev/null; then
					echo "  Removed: bun global openclaw"
					((ITEMS_REMOVED++)) || true
				else
					echo "  ! bun removal failed"
					((ITEMS_FAILED++)) || true
				fi
			fi
		fi
	fi

	# Stray binaries in standard locations
	remove_file "/usr/local/bin/openclaw" "CLI binary (/usr/local/bin)"
	remove_file "/opt/homebrew/bin/openclaw" "CLI binary (Homebrew)"
}

################################################################################
# Docker cleanup
################################################################################

remove_docker() {
	echo ""
	echo "Removing Docker containers and images..."

	if ! command_exists docker; then
		echo "  Docker not found, skipping"
		return 0
	fi

	# Check if Docker daemon is running
	if ! docker info >/dev/null 2>&1; then
		echo "  Docker daemon not running, skipping"
		return 0
	fi

	# Stop and remove running containers
	local running
	running=$(docker ps -q --filter "name=openclaw" 2>/dev/null || echo "")
	# Also try filtering by image name containing "openclaw"
	if [[ -z "$running" ]]; then
		running=$(docker ps -q --filter "ancestor=openclaw" 2>/dev/null || echo "")
	fi
	if [[ -z "$running" ]]; then
		running=$(docker ps -q | xargs docker inspect --format '{{.Name}} {{.Config.Image}}' 2>/dev/null | grep -i openclaw | cut -d' ' -f1 | sed 's/^//' || echo "")
	fi
	if [[ -n "$running" ]]; then
		if [[ "$DRY_RUN" == true ]]; then
			echo "  [DRY RUN] Would stop and remove running containers"
		else
			while IFS= read -r cid; do
				if docker stop "$cid" 2>/dev/null && docker rm "$cid" 2>/dev/null; then
					echo "  Removed container: $cid"
					((ITEMS_REMOVED++)) || true
				fi
			done <<< "$running"
		fi
	fi

	# Remove stopped containers
	local stopped
	stopped=$(docker ps -aq --filter "name=openclaw" 2>/dev/null || echo "")
	# Also try filtering by image name containing "openclaw"
	if [[ -z "$stopped" ]]; then
		stopped=$(docker ps -aq --filter "ancestor=openclaw" 2>/dev/null || echo "")
	fi
	if [[ -z "$stopped" ]]; then
		stopped=$(docker ps -aq | xargs docker inspect --format '{{.Name}} {{.Config.Image}}' 2>/dev/null | grep -i openclaw | cut -d' ' -f1 | sed 's/^//' || echo "")
	fi
	if [[ -n "$stopped" ]]; then
		if [[ "$DRY_RUN" == true ]]; then
			echo "  [DRY RUN] Would remove stopped containers"
		else
			while IFS= read -r cid; do
				if docker rm "$cid" 2>/dev/null; then
					echo "  Removed stopped container: $cid"
					((ITEMS_REMOVED++)) || true
				fi
			done <<< "$stopped"
		fi
	fi

	# Remove images
	local images
	images=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -i openclaw || echo "")
	if [[ -n "$images" ]]; then
		if [[ "$DRY_RUN" == true ]]; then
			echo "  [DRY RUN] Would remove OpenClaw images"
		else
			while IFS= read -r img; do
				if docker rmi "$img" 2>/dev/null; then
					echo "  Removed image: $img"
					((ITEMS_REMOVED++)) || true
				fi
			done <<< "$images"
		fi
	fi

	# Tear down docker-compose stacks
	if [[ "$ALL_USERS" == true ]]; then
		for user_home in /Users/*; do
			[[ ! -d "$user_home" ]] && continue
			[[ "$user_home" == "/Users/Shared" || "$user_home" == "/Users/Guest" ]] && continue
			local compose_file="${user_home}/openclaw/docker-compose.yml"
			if [[ -f "$compose_file" ]]; then
				if [[ "$DRY_RUN" == true ]]; then
					echo "  [DRY RUN] Would run docker-compose down in $(dirname "$compose_file")"
				else
					(cd "$(dirname "$compose_file")" && docker-compose down 2>/dev/null) \
						&& echo "  Tore down compose stack: $(dirname "$compose_file")" || true
				fi
			fi
		done
	elif [[ -f "${HOME:-}/openclaw/docker-compose.yml" ]]; then
		if [[ "$DRY_RUN" == true ]]; then
			echo "  [DRY RUN] Would run docker-compose down in ${HOME}/openclaw"
		else
			(cd "${HOME}/openclaw" && docker-compose down 2>/dev/null) \
				&& echo "  Tore down compose stack: ${HOME}/openclaw" || true
		fi
	fi
}


################################################################################
# Final verification
################################################################################

verify_removal() {
	echo ""
	echo "Verifying removal..."

	local issues=0

	# Processes
	if pgrep -f "openclaw|moltbot|clawdbot" >/dev/null 2>&1; then
		echo "  ! Some OpenClaw processes still running (restart may be needed)"
		((issues++))
	else
		echo "  OK  No OpenClaw processes running"
	fi

	# LaunchAgents
	local remaining_agents
	remaining_agents=$(find /Users/*/Library/LaunchAgents \( \
		-name "bot.molt.*" -o -name "com.openclaw.*" -o -name "com.clawdbot.*" \
	\) 2>/dev/null | wc -l | tr -d ' ')
	if [[ "$remaining_agents" -gt 0 ]]; then
		echo "  ! Found $remaining_agents remaining LaunchAgent(s)"
		((issues++))
	else
		echo "  OK  All LaunchAgents removed"
	fi

	# Config directories
	local remaining_configs
	remaining_configs=$(find /Users -maxdepth 2 \( \
		-name ".openclaw" -o -name ".moltbot" -o -name ".clawdbot" -o -name ".molthub" \
		\) -type d 2>/dev/null | wc -l | tr -d ' ')
	if [[ "$remaining_configs" -gt 0 ]]; then
		echo "  ! Found $remaining_configs remaining config director(y/ies)"
		((issues++))
	else
		echo "  OK  All config directories removed"
	fi

	# CLI availability
	if command_exists openclaw; then
		echo "  ! openclaw CLI still in PATH (restart your terminal)"
		((issues++))
	else
		echo "  OK  openclaw CLI removed"
	fi

	# Docker
	if command_exists docker && docker info >/dev/null 2>&1; then
		local docker_count
		docker_count=$(docker ps -aq --filter "name=openclaw" 2>/dev/null | wc -l | tr -d ' ')
		if [[ "$docker_count" -eq 0 ]]; then
			docker_count=$(docker ps -aq --filter "ancestor=openclaw" 2>/dev/null | wc -l | tr -d ' ')
		fi
		if [[ "$docker_count" -eq 0 ]]; then
			docker_count=$(docker ps -aq | xargs docker inspect --format '{{.Name}} {{.Config.Image}}' 2>/dev/null | grep -ci openclaw)
			docker_count=${docker_count:-0}
		fi
		if [[ "$docker_count" -gt 0 ]]; then
			echo "  ! Found $docker_count remaining Docker container(s)"
			((issues++))
		else
			echo "  OK  No OpenClaw Docker containers"
		fi
	fi

	return "$issues"
}

################################################################################
# Main execution
################################################################################

echo "=========================================="
echo "  OpenClaw Removal Script"
echo "=========================================="

if [[ "$DRY_RUN" == true ]]; then
	echo "  Running in DRY RUN mode — no changes will be made"
fi

if [[ "$ALL_USERS" == true ]] && [[ $EUID -ne 0 ]]; then
	echo "Error: --all requires sudo"
	exit 1
fi

# Prepare backup directory
BACKUP_DIR=""
if [[ "$NO_BACKUP" == false ]] && [[ "$DRY_RUN" == false ]]; then
	BACKUP_DIR="/tmp/openclaw_backup_$(date +%Y%m%d_%H%M%S)"
	mkdir -p "$BACKUP_DIR"
	echo "  Backups: $BACKUP_DIR"
fi

echo "Proceeding with OpenClaw removal..."

# 1. Kill processes FIRST (before LaunchAgent removal to prevent respawn)
if [[ "$DOCKER_ONLY" == false ]]; then
	kill_openclaw_processes
fi

# 2. Per-user removal (LaunchAgents removed while processes are dead)
if [[ "$DOCKER_ONLY" == false ]]; then
	if [[ "$ALL_USERS" == true ]]; then
		for user_home in /Users/*; do
			[[ ! -d "$user_home" ]] && continue
			[[ "$user_home" == "/Users/Shared" || "$user_home" == "/Users/Guest" ]] && continue
			remove_for_user "$user_home" "$(basename "$user_home")" "$BACKUP_DIR"
		done
	else
		if [[ -n "${HOME:-}" ]]; then
			remove_for_user "$HOME" "$(whoami)" "$BACKUP_DIR"
		else
			echo "Error: Could not determine home directory"
			exit 1
		fi
	fi

	# 3. Global package manager and system-wide removal
	remove_package_managers

	if [[ $EUID -eq 0 ]] || [[ "$ALL_USERS" == true ]]; then
		remove_directory "/Applications/OpenClaw.app" "OpenClaw.app (system)"
	fi
fi

# 4. Docker cleanup
remove_docker

# 5. Final process cleanup (kill any processes that may have restarted)
if [[ "$DOCKER_ONLY" == false ]]; then
	kill_openclaw_processes
fi

# 6. Final sweep: remove any config directories recreated during removal
if [[ "$DOCKER_ONLY" == false ]]; then
	if [[ "$ALL_USERS" == true ]]; then
		for user_home in /Users/*; do
			[[ ! -d "$user_home" ]] && continue
			[[ "$user_home" == "/Users/Shared" || "$user_home" == "/Users/Guest" ]] && continue
			for dir_name in "${CONFIG_DIRS[@]}"; do
				if [[ -d "${user_home}/${dir_name}" ]]; then
					remove_directory "${user_home}/${dir_name}" "${dir_name} ($(basename "$user_home"), final sweep)"
				fi
			done
		done
	else
		for dir_name in "${CONFIG_DIRS[@]}"; do
			if [[ -d "${HOME}/${dir_name}" ]]; then
				remove_directory "${HOME}/${dir_name}" "${dir_name} ($(whoami), final sweep)"
			fi
		done
	fi
fi

# Summary
echo "=========================================="
echo "  Items removed: $ITEMS_REMOVED"
[[ $ITEMS_FAILED -gt 0 ]] && echo "  Items failed:  $ITEMS_FAILED"

if [[ -n "$BACKUP_DIR" ]] && [[ -d "$BACKUP_DIR" ]]; then
	echo "  Backups: $BACKUP_DIR"
fi

if [[ "$DRY_RUN" == true ]]; then
	echo "  This was a dry run. Re-run without --dry-run to remove."
else
	verify_removal || true
fi

echo "OpenClaw removal complete."
exit 0