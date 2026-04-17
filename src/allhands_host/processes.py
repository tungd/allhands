import asyncio
from dataclasses import dataclass

from allhands_host.launchers.base import LaunchCommand


@dataclass
class RunningProcess:
    process: asyncio.subprocess.Process


async def spawn(command: LaunchCommand) -> RunningProcess:
    process = await asyncio.create_subprocess_exec(
        *command.argv,
        cwd=str(command.cwd),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    return RunningProcess(process=process)
