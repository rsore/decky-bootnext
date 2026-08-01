import asyncio
import os
import re
from typing import Optional, TypedDict

import decky


class BootEntry(TypedDict):
    id: str
    label: str
    active: bool


class BootState(TypedDict):
    current: Optional[str]
    next: Optional[str]
    order: list[str]
    entries: list[BootEntry]


ENTRY_PATTERN = re.compile(
    r"^Boot(?P<id>[0-9A-Fa-f]{4})(?P<active>\*)?\s+(?P<label>.+?)\s*$"
)
BOOT_NEXT_PATH = (
    "/sys/firmware/efi/efivars/BootNext-8be4df61-93ca-11d2-aa0d-00e098032b8c"
)


def parse_id(value: str) -> Optional[str]:
    entry_id = value.strip()
    if re.fullmatch(r"[0-9A-Fa-f]{4}", entry_id):
        return entry_id.upper()
    return None


def parse_boot_state(output: str) -> BootState:
    current: Optional[str] = None
    next_entry: Optional[str] = None
    order: list[str] = []
    entries: list[BootEntry] = []

    for line in output.splitlines():
        if line.startswith("BootCurrent:"):
            current = parse_id(line.partition(":")[2])
            continue

        if line.startswith("BootNext:"):
            next_entry = parse_id(line.partition(":")[2])
            continue

        if line.startswith("BootOrder:"):
            value = line.partition(":")[2].strip()
            order = []
            for entry_id in value.split(","):
                entry_id = entry_id.strip()
                if re.fullmatch(r"[0-9A-Fa-f]{4}", entry_id):
                    order.append(entry_id.upper())
            continue

        match = ENTRY_PATTERN.match(line)
        if match:
            label = match.group("label").split("\t", maxsplit=1)[0].rstrip()
            entries.append(
                {
                    "id": match.group("id").upper(),
                    "label": label,
                    "active": match.group("active") == "*",
                }
            )

    if not entries:
        raise ValueError("efibootmgr returned no UEFI boot entries")

    return {
        "current": current,
        "next": next_entry,
        "order": order,
        "entries": entries,
    }


class Plugin:
    async def get_boot_state(self) -> BootState:
        output = await self._run_efibootmgr()

        try:
            return parse_boot_state(output)
        except ValueError as error:
            raise RuntimeError(str(error)) from error

    async def set_boot_next(self, entry_id: str) -> BootState:
        try:
            if not re.fullmatch(r"[0-9A-Fa-f]{4}", entry_id):
                raise ValueError("Invalid UEFI boot entry ID")

            entry_id = entry_id.upper()
            state = await self.get_boot_state()
            entry = next(
                (item for item in state["entries"] if item["id"] == entry_id),
                None,
            )

            if entry is None:
                raise ValueError(f"UEFI boot entry {entry_id} does not exist")
            if not entry["active"]:
                raise ValueError(f"UEFI boot entry {entry_id} is inactive")

            await self._run_efibootmgr("--bootnext", entry_id)
            decky.logger.info(
                "Set BootNext to %s (%s)",
                entry_id,
                entry["label"],
            )
            return await self.get_boot_state()
        except Exception as error:
            message = f"Failed to set next boot: {error}"
            await self._emit_action_error(message)
            raise RuntimeError(message) from error

    async def clear_boot_next(self) -> BootState:
        try:
            try:
                os.unlink(BOOT_NEXT_PATH)
            except FileNotFoundError:
                pass

            state = await self.get_boot_state()
            decky.logger.info("Cleared BootNext")
            return state
        except Exception as error:
            message = f"Failed to clear next boot: {error}"
            await self._emit_action_error(message)
            raise RuntimeError(message) from error

    async def _emit_action_error(self, message: str) -> None:
        decky.logger.exception(message)
        await decky.emit("bootnext_error", message)

    async def _run_efibootmgr(self, *arguments: str) -> str:
        executable = "/usr/bin/efibootmgr"
        if not os.path.isfile(executable):
            raise RuntimeError("efibootmgr is not installed")

        return await self._run_command(executable, *arguments)

    async def _run_command(self, executable: str, *arguments: str) -> str:
        command_name = os.path.basename(executable)
        environment = os.environ.copy()
        environment["LC_ALL"] = "C"
        environment.pop("LD_LIBRARY_PATH", None)
        environment.pop("LD_PRELOAD", None)

        process = await asyncio.create_subprocess_exec(
            executable,
            *arguments,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=environment,
        )

        try:
            stdout, stderr = await asyncio.wait_for(
                process.communicate(),
                timeout=5,
            )
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise RuntimeError(f"{command_name} timed out") from None

        if process.returncode != 0:
            message = stderr.decode(errors="replace").strip()
            raise RuntimeError(message or f"{command_name} failed")

        return stdout.decode(errors="replace")

    async def _main(self):
        decky.logger.info("BootNext started")

    async def _unload(self):
        decky.logger.info("BootNext stopping")

    async def _uninstall(self):
        decky.logger.info("BootNext uninstalled")
