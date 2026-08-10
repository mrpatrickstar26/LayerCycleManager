// ============================================================
// Layer Cycle Manager
// File: lcm_ui.dcl
// Main DCL dialog: ByLayer toggle + ACI picker + arrow deletion
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
  }


  // ------------------------------------------------------------
  // Arrow parameters
  // ------------------------------------------------------------

  : boxed_column {
    label = "Параметры стрелок";

    : row {
      : toggle {
        key = "by_layer";
        label = "По слою";
        value = "0";
      }
    }

    : row {
      : text {
        label = "Цвет (ACI):";
        width = 18;
      }

      : edit_box {
        key = "aci";
        width = 10;
      }

      : button {
        key = "pick_aci";
        label = "Выбрать цвет...";
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

    : row {
      : text {
        label = "Слой удаления:";
        width = 18;
      }

      : popup_list {
        key = "del_layer";
        width = 20;
      }
    }

    : row {
      : text {
        key = "del_count";
        label = "Стрелок: -";
        width = 18;
      }

      : button {
        key = "delete_arrows";
        label = "Удалить";
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

      : edit_box {
        key = "map_from_edit";
        width = 20;
      }

      : popup_list {
        key = "map_from";
        width = 15;
      }
    }

    : row {
      : text {
        label = "В последний слой:";
        width = 20;
      }

      : edit_box {
        key = "map_to_edit";
        width = 20;
      }

      : popup_list {
        key = "map_to";
        width = 15;
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
      key = "minimize";
      label = "В чертёж";
    }

    : button {
      key = "cancel";
      label = "Закрыть";
      is_cancel = true;
    }
  }
}