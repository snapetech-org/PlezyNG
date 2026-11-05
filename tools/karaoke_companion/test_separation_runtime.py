"""Optional native CPU checks; no trained models or network downloads."""
import importlib.util
from pathlib import Path
import pickle
import tempfile
import unittest
import wave

READY = all(importlib.util.find_spec(name) for name in ('torch', 'torchaudio', 'torchcodec', 'demucs'))


class UnapprovedCheckpointClass:
    pass


@unittest.skipUnless(READY, 'optional separation runtime is not installed')
class SeparationRuntimeTest(unittest.TestCase):
    def test_checkpoint_globals_reject_unapproved_classes(self):
        import torch
        from demucs_runner import checkpoint_globals
        with tempfile.TemporaryDirectory(prefix='karaoke-checkpoint-') as directory:
            path = Path(directory) / 'unapproved.th'
            # Local rejection fixture; this class must never be accepted by the loader.
            # nosemgrep: trailofbits.python.pickles-in-pytorch.pickles-in-pytorch
            torch.save({'klass': UnapprovedCheckpointClass}, path)
            with checkpoint_globals(), self.assertRaises(pickle.UnpicklingError):
                # Deliberately exercise rejection with the explicit safe loading mode.
                # nosemgrep: trailofbits.python.pickles-in-pytorch.pickles-in-pytorch
                torch.load(path, weights_only=True)

    def test_local_cpu_separation_and_audio_backend(self):
        import torch
        from demucs.demucs import Demucs
        torch.set_num_threads(2)
        torch.manual_seed(1)
        model = Demucs(sources=['drums', 'bass', 'other', 'vocals'], channels=4,
            depth=1, lstm_layers=0, dconv_mode=0, resample=False, samplerate=8000, segment=8)
        self.check_local_separation(model)

    def test_local_htdemucs_transformer_separation(self):
        import torch
        from demucs.htdemucs import HTDemucs
        torch.set_num_threads(2)
        torch.manual_seed(1)
        model = HTDemucs(sources=['drums', 'bass', 'other', 'vocals'], channels=8,
            channels_time=8, nfft=64, depth=2, dconv_mode=0, t_layers=1, t_heads=2,
            norm_groups=1, samplerate=8000, segment=8, use_train_segment=False)
        self.check_local_separation(model)

    def check_local_separation(self, model):
        import hashlib
        import math
        import struct
        import torch
        from demucs.states import serialize_model
        from omegaconf import OmegaConf
        from worker import separate
        with tempfile.TemporaryDirectory(prefix='karaoke-separation-') as directory:
            root = Path(directory)
            models, out = root / 'models', root / 'output'
            models.mkdir(); out.mkdir()
            checkpoint = root / 'model.th'
            # Synthetic constructor/tensor fixture created by this test, never downloaded.
            # nosemgrep: trailofbits.python.pickles-in-pytorch.pickles-in-pytorch
            torch.save(serialize_model(model, OmegaConf.create({})), checkpoint)
            digest = hashlib.sha256(checkpoint.read_bytes()).hexdigest()[:8]
            checkpoint.rename(models / f'00000000-{digest}.th')
            (models / 'htdemucs.yaml').write_text('models: ["00000000"]\n')
            source = root / 'source.wav'
            with wave.open(str(source), 'wb') as writer:
                writer.setnchannels(2); writer.setsampwidth(2); writer.setframerate(8000)
                writer.writeframes(b''.join(struct.pack('<hh', sample, sample) for sample in
                    (int(8000 * math.sin(i * 2 * math.pi * 440 / 8000)) for i in range(2000))))
            separate(source, out, {}, models)
            self.assertEqual({'lead.wav', 'instrumental.wav'}, {p.name for p in out.iterdir()})
            for name in ('lead.wav', 'instrumental.wav'):
                with wave.open(str(out / name), 'rb') as reader:
                    self.assertEqual((2, 3, 48000, 12000),
                        (reader.getnchannels(), reader.getsampwidth(), reader.getframerate(), reader.getnframes()))


if __name__ == '__main__':
    unittest.main()
