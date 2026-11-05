"""Run local Demucs models with the patched weights-only checkpoint loader."""
from __future__ import annotations
import os
import sys


def checkpoint_globals():
    import torch
    from demucs.demucs import Demucs
    from demucs.hdemucs import HDemucs
    from demucs.htdemucs import HTDemucs
    from torch.torch_version import TorchVersion
    # Demucs stores the constructor class alongside tensor state. Do not allow
    # arbitrary pickle globals or disable weights-only loading for old models.
    return torch.serialization.safe_globals([Demucs, HDemucs, HTDemucs, TorchVersion])


def main():
    if '--repo' not in sys.argv and not any(arg in sys.argv for arg in ('-h', '--help')):
        raise ValueError('Provision and select an approved local model repository')
    os.environ['TORCH_FORCE_WEIGHTS_ONLY_LOAD'] = '1'
    with checkpoint_globals():
        from demucs.separate import main as separate
        separate()


if __name__ == '__main__':
    main()
