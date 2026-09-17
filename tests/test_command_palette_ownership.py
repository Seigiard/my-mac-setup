import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent


class CommandPaletteOwnershipTests(unittest.TestCase):
    def test_repository_keeps_one_user_catalog_and_no_local_plugin(self) -> None:
        repository_catalog = REPOSITORY_ROOT / ".herdr/command-palette"
        vendored_plugin = REPOSITORY_ROOT / "home/private_dot_config/herdr/plugins/command-palette"
        self.assertTrue(
            (REPOSITORY_ROOT / "home/private_dot_config/herdr/command-palette/commands.toml").is_file()
        )
        self.assertFalse(repository_catalog.exists() or repository_catalog.is_symlink())
        self.assertFalse(vendored_plugin.exists() or vendored_plugin.is_symlink())


if __name__ == "__main__":
    unittest.main()
