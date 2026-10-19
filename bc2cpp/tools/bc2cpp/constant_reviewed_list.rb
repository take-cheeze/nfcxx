# frozen_string_literal: true

# CONSTANT_REVIEWED (docs/adr/0491): the engine constants the bc2cpp type check leaves untyped, read and reviewed.
# The gate (tools/bc2cpp/constant_reviewed.rb, TC1017) fails on an unlisted untyped constant and on a listed one
# that is typed or gone, so this list only shrinks. Regenerate with
# `MRBC=... ruby scripts/bc2cpp/constant_reviewed_update.rb --write`, after reading each added name's source.
require 'set'

CONSTANT_REVIEWED = Set[
  "Game::ChipSet::ALL_DIRS",
  "LCF::Schema::SAVE_PARTY_LOCATION",
  "RGSS::Graphics::BRIGHTNESS_Z",
  "RPG2k::Scene::Base::UTF8_AWARE_STRINGS",
  "RPG2k::Scene::ChipsetEditor::BLOCKED_COLOR",
  "RPG2k::Scene::ChipsetEditor::CURSOR_COLOR",
  "RPG2k::Scene::ChipsetEditor::FOOTER_H",
  "RPG2k::Scene::ChipsetEditor::HINT_COLOR",
  "RPG2k::Scene::ChipsetEditor::PASSABLE_COLOR",
  "RPG2k::Scene::ChipsetEditor::TEXT_COLOR",
  "RPG2k::Scene::ChipsetEditor::UNKNOWN_COLOR",
  "RPG2k::Scene::EquipMenu::CAND_H",
  "RPG2k::Scene::EquipMenu::SLOT_W",
  "RPG2k::Scene::Map::COLS",
  "RPG2k::Scene::Map::NAME_CELLS",
  "RPG2k::Scene::Map::NAME_CHARS",
  "RPG2k::Scene::Map::NAME_KANA_LAST_HIRAGANA",
  "RPG2k::Scene::Map::NAME_KANA_LAST_KATAKANA",
  "RPG2k::Scene::Map::ROWS",
  "RPG2k::Scene::Map::SLIDE_UNITS",
  "RPG2k::Scene::MapViewer::BLOCKED_COLOR",
  "RPG2k::Scene::MapViewer::CURSOR_COLOR",
  "RPG2k::Scene::MapViewer::FOOTER_H",
  "RPG2k::Scene::MapViewer::HINT_COLOR",
  "RPG2k::Scene::MapViewer::PASSABLE_COLOR",
  "RPG2k::Scene::MapViewer::TEXT_COLOR",
  "RPG2k::Scene::MapViewer::UNKNOWN_COLOR",
  "RPG2k::Scene::Order::LIST_X",
  "RPG2k::Scene::SaveLoad::SLOT_TOP",
  "RPG2k::Scene::SaveLoad::VISIBLE_SLOTS",
  "RPG2k::Scene::SkillMenu::CELL_CURSOR_W",
  "RPG2k::Scene::SkillMenu::DOWN_ARROW_Y",
  "RPG2k::Scene::StatusMenu::EQUIP_WINDOW_H",
  "RPG2k::Scene::StatusMenu::GOLD_WINDOW_H",
  "STDERR",
  "STDIN",
  "STDOUT",
].freeze
