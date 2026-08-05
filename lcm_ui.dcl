// ============================================================
// Layer Cycle Manager
// File: lcm_ui.dcl
// Stage 4: main DCL dialog
// ============================================================

lcm_main_dlg : dialog {
  label = "Layer Cycle Manager";

  // ------------------------------------------------------------
  // Layer selection
  // ------------------------------------------------------------

  : boxed_column {
    label = "Выбор слоёв";

    : row {
      : text {
        label = "Нулевой цикл:";
        width = 18;
      }

      : popup_list {
        key = "layer_zero";
        width = 35;
      }
    }

    : row {
      : text {
        label = "Последний цикл:";
        width = 18;
      }

      : popup_list {
        key = "layer_last";
        width = 35;
      }
    }

    : row {
      : button {
        key = "refresh_layers";
        label = "Обновить слои";
      }
    }
  }


  // ------------------------------------------------------------
  // Arrow parameters
  // ------------------------------------------------------------

  : boxed_column {
    label = "Параметры стрелок";

    : row {
      : text {
        label = "Цвет:";
        width = 18;
      }

      : popup_list {
        key = "color_mode";
        width = 20;
      }
    }

    : row {
      : text {
        label = "ACI:";
        width = 18;
      }

      : edit_box {
        key = "aci";
        width = 10;
      }

      : button {
        key = "pick_aci";
        label = "Выбрать...";
      }
    }

    : row {
      : text {
        label = "RGB:";
        width = 18;
      }

      : edit_box {
        key = "rgb_r";
        width = 6;
      }

      : edit_box {
        key = "rgb_g";
        width = 6;
      }

      : edit_box {
        key = "rgb_b";
        width = 6;
      }
    }

    : row {
      : text {
        label = "Высота текста:";
        width = 18;
      }

      : edit_box {
        key = "text_height";
        width = 10;
      }
    }

    : row {
      : text {
        label = "Масштаб:";
        width = 18;
      }

      : edit_box {
        key = "scale";
        width = 10;
      }
    }
  }


  // ------------------------------------------------------------
  // Point mapping
  // ------------------------------------------------------------

  : boxed_column {
    label = "Сопоставление точек";

    : text {
      key = "info";
      label = "Выберите слои для загрузки точек";
      width = 70;
    }

    : row {
      : text {
        label = "Из нулевого слоя:";
        width = 20;
      }

      : popup_list {
        key = "map_from";
        width = 30;
      }
    }

    : row {
      : text {
        label = "В последний слой:";
        width = 20;
      }

      : popup_list {
        key = "map_to";
        width = 30;
      }
    }

    : list_box {
      key = "mappings";
      width = 70;
      height = 8;
    }

    : row {
      : button {
        key = "add_map";
        label = "Добавить";
      }

      : button {
        key = "update_map";
        label = "Обновить";
      }

      : button {
        key = "remove_map";
        label = "Удалить";
      }
    }

    : row {
      : button {
        key = "auto_map";
        label = "Авто-сопоставление";
      }

      : button {
        key = "clear_map";
        label = "Очистить все";
      }
    }
  }


  // ------------------------------------------------------------
  // Dialog buttons
  // ------------------------------------------------------------

  : row {
    : button {
      key = "accept";
      label = "Выполнить";
      is_default = true;
    }

    : button {
      key = "cancel";
      label = "Закрыть";
      is_cancel = true;
    }
  }
}