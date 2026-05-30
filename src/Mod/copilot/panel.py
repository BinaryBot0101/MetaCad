# SPDX-License-Identifier: LGPL-2.1-or-later
"""Qt dock panel for FreeCAD Copilot."""

import base64
import mimetypes
import os
import traceback

import FreeCAD as App
import FreeCADGui as Gui

try:
    from PySide import QtCore, QtGui
    QtWidgets = QtGui
except ImportError:
    from PySide2 import QtCore, QtWidgets

from constants import MAX_IMAGE_SIZE_BYTES
from executor import CopilotExecutor
from provider import describe_plan, get_provider


PANEL_OBJECT_NAME = "CopilotDockPanel"

# Modern CAD-dark stylesheet (AutoCAD / SolidWorks inspired)
_CAD_STYLESHEET = """
QWidget {
    background-color: #2B2B2B;
    color: #ECECEC;
    font-family: "Segoe UI", "Microsoft Sans Serif", sans-serif;
    font-size: 12px;
}

QPlainTextEdit {
    background-color: #1E1E1E;
    color: #ECECEC;
    border: 1px solid #404040;
    border-radius: 3px;
    padding: 6px;
    selection-background-color: #264F78;
}

QPlainTextEdit:focus {
    border: 1px solid #0078D4;
}

QLabel {
    color: #AAAAAA;
    background-color: transparent;
}

QLabel#HeaderLabel {
    color: #FFFFFF;
    font-size: 13px;
    font-weight: bold;
    padding: 4px 0px;
}

QLabel#StatusLabel {
    color: #4CAF50;
    font-size: 11px;
    padding: 2px 6px;
    background-color: #1E1E1E;
    border-radius: 2px;
}

QPushButton {
    background-color: #3C3C3C;
    color: #ECECEC;
    border: 1px solid #505050;
    border-radius: 3px;
    padding: 6px 14px;
    min-height: 18px;
}

QPushButton:hover {
    background-color: #505050;
    border: 1px solid #0078D4;
}

QPushButton:pressed {
    background-color: #0078D4;
    border: 1px solid #0078D4;
}

QPushButton#PrimaryButton {
    background-color: #0078D4;
    border: 1px solid #0078D4;
    color: #FFFFFF;
    font-weight: bold;
}

QPushButton#PrimaryButton:hover {
    background-color: #2D8CFF;
    border: 1px solid #2D8CFF;
}

QPushButton#PrimaryButton:pressed {
    background-color: #005A9E;
    border: 1px solid #005A9E;
}

QPushButton#DangerButton {
    background-color: #3C3C3C;
    border: 1px solid #505050;
    color: #EF5350;
}

QPushButton#DangerButton:hover {
    background-color: #EF5350;
    border: 1px solid #EF5350;
    color: #FFFFFF;
}

QFrame#Separator {
    background-color: #404040;
    max-height: 1px;
    min-height: 1px;
}

QFrame#AccentBar {
    background-color: #0078D4;
    max-width: 3px;
    min-width: 3px;
}
"""



class CopilotPanel(QtWidgets.QDockWidget):
    """Dockable prompt interface."""

    def __init__(self, parent=None):
        super(CopilotPanel, self).__init__("Copilot", parent)
        self.setObjectName(PANEL_OBJECT_NAME)
        self.executor = CopilotExecutor()
        self.image_path = None
        self.image_data_url = None
        self._build_ui()

    @property
    def provider(self):
        """Return a fresh provider instance (environment may change)."""
        return get_provider()

    def _build_ui(self):
        root = QtWidgets.QWidget()
        root.setStyleSheet(_CAD_STYLESHEET)
        layout = QtWidgets.QVBoxLayout(root)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(8)

        # Header with accent bar
        header = QtWidgets.QHBoxLayout()
        header.setSpacing(0)
        accent = QtWidgets.QFrame()
        accent.setObjectName("AccentBar")
        accent.setFixedWidth(3)
        header_title = QtWidgets.QLabel("COPILOT AI")
        header_title.setObjectName("HeaderLabel")
        self.status_dot = QtWidgets.QLabel("READY")
        self.status_dot.setObjectName("StatusLabel")
        header.addWidget(accent)
        header.addSpacing(6)
        header.addWidget(header_title)
        header.addStretch(1)
        header.addWidget(self.status_dot)
        layout.addLayout(header)

        sep1 = QtWidgets.QFrame()
        sep1.setObjectName("Separator")
        layout.addWidget(sep1)

        # Prompt area (command-line style)
        prompt_label = QtWidgets.QLabel("COMMAND")
        layout.addWidget(prompt_label)
        self.prompt = QtWidgets.QPlainTextEdit()
        self.prompt.setPlaceholderText(
            "create a box length 40 width 20 height 10\n"
            "move selected x 10 y 0 z 5\n"
            "color selected blue"
        )
        self.prompt.setMaximumBlockCount(6)
        self.prompt.setMinimumHeight(70)
        self.prompt.setMaximumHeight(100)
        layout.addWidget(self.prompt)

        # Image status bar
        image_bar = QtWidgets.QHBoxLayout()
        image_bar.setSpacing(6)
        self.image_label = QtWidgets.QLabel("No image attached")
        self.attach_image_button = QtWidgets.QPushButton("")
        self.attach_image_button.setToolTip("Attach reference image")
        self.attach_image_button.setText("")
        self.attach_image_button.setFixedSize(28, 28)
        self.attach_image_button.setStyleSheet("QPushButton { font-size: 14px; padding: 0px; }")
        self.attach_image_button.setText("")
        self._set_button_icon_text(self.attach_image_button, "+")
        self.clear_image_button = QtWidgets.QPushButton("")
        self.clear_image_button.setToolTip("Clear image")
        self.clear_image_button.setFixedSize(28, 28)
        self.clear_image_button.setStyleSheet("QPushButton { font-size: 14px; padding: 0px; }")
        self._set_button_icon_text(self.clear_image_button, "x")
        image_bar.addWidget(self.image_label, 1)
        image_bar.addWidget(self.attach_image_button)
        image_bar.addWidget(self.clear_image_button)
        layout.addLayout(image_bar)

        # Toolbar
        toolbar = QtWidgets.QHBoxLayout()
        toolbar.setSpacing(8)
        self.run_button = QtWidgets.QPushButton("RUN")
        self.run_button.setObjectName("PrimaryButton")
        self.run_button.setMinimumWidth(80)
        self.plan_button = QtWidgets.QPushButton("PREVIEW")
        self.plan_button.setMinimumWidth(80)
        self.clear_button = QtWidgets.QPushButton("CLEAR")
        self.clear_button.setObjectName("DangerButton")
        self.clear_button.setMinimumWidth(70)
        toolbar.addWidget(self.run_button)
        toolbar.addWidget(self.plan_button)
        toolbar.addStretch(1)
        toolbar.addWidget(self.clear_button)
        layout.addLayout(toolbar)

        sep2 = QtWidgets.QFrame()
        sep2.setObjectName("Separator")
        layout.addWidget(sep2)

        # Console output
        console_label = QtWidgets.QLabel("CONSOLE OUTPUT")
        layout.addWidget(console_label)
        self.output = QtWidgets.QPlainTextEdit()
        self.output.setReadOnly(True)
        self.output.setMinimumHeight(160)
        font = QtGui.QFont("Consolas", 10)
        if not font.exactMatch():
            font = QtGui.QFont("Courier New", 10)
        if not font.exactMatch():
            font = QtGui.QFont("Monospace", 10)
        self.output.setFont(font)
        self.output.setStyleSheet(
            self.output.styleSheet() +
            " QPlainTextEdit { background-color: #151515; border: 1px solid #2A2A2A; }"
        )
        layout.addWidget(self.output, 1)

        self.setWidget(root)

        self.run_button.clicked.connect(self.run_prompt)
        self.plan_button.clicked.connect(self.preview_plan)
        self.clear_button.clicked.connect(self._clear_console)
        self.attach_image_button.clicked.connect(self.attach_image)
        self.clear_image_button.clicked.connect(self.clear_image)

    def attach_image(self):
        try:
            path, _filter = QtWidgets.QFileDialog.getOpenFileName(
                self,
                "Attach reference image",
                "",
                "Images (*.png *.jpg *.jpeg *.webp *.bmp);;All Files (*)",
            )
            if not path:
                return
            if os.path.getsize(path) > MAX_IMAGE_SIZE_BYTES:
                raise ValueError("Image is larger than {0} MB. Please choose a smaller image.".format(MAX_IMAGE_SIZE_BYTES // (1024 * 1024)))
            mime_type = mimetypes.guess_type(path)[0] or "image/png"
            with open(path, "rb") as image_file:
                encoded = base64.b64encode(image_file.read()).decode("ascii")
            self.image_path = path
            self.image_data_url = "data:{0};base64,{1}".format(mime_type, encoded)
            self.image_label.setText(os.path.basename(path))
            self._write("Attached image: {0}".format(path))
        except Exception as err:
            self._write_error(err)

    def clear_image(self):
        self.image_path = None
        self.image_data_url = None
        self.image_label.setText("No image attached")

    def preview_plan(self):
        try:
            plan = self.provider.plan(self.prompt.toPlainText(), self._context())
            self._write(describe_plan(plan))
        except Exception as err:
            self._write_error(err)

    def run_prompt(self):
        try:
            plan = self.provider.plan(self.prompt.toPlainText(), self._context())
            self._write("Plan:\n{0}".format(describe_plan(plan)))
            results = self.executor.run(plan)
            self._write("\nResult:\n{0}".format("\n".join(results)))
        except Exception as err:
            self._write_error(err)

    def _write(self, text):
        self.output.setPlainText(text)
        App.Console.PrintMessage("{0}\n".format(text))
        self._set_status("READY", "#4CAF50")

    def _write_error(self, err):
        message = "Copilot error: {0}".format(err)
        self.output.setPlainText(message)
        App.Console.PrintError("{0}\n{1}\n".format(message, traceback.format_exc()))
        self._set_status("ERROR", "#EF5350")

    def _clear_console(self):
        self.output.clear()
        self._set_status("READY", "#4CAF50")

    def _set_status(self, text, color):
        self.status_dot.setText(text)
        self.status_dot.setStyleSheet(
            "QLabel#StatusLabel {{ color: {0}; background-color: #1E1E1E; padding: 2px 6px; border-radius: 2px; font-size: 11px; }}".format(color)
        )

    def _set_button_icon_text(self, button, text):
        button.setText(text)

    def _context(self):
        context = _context()
        if self.image_data_url:
            context["image"] = {
                "path": self.image_path,
                "data_url": self.image_data_url,
            }
        return context


def show_panel():
    main_window = Gui.getMainWindow()
    panel = main_window.findChild(QtWidgets.QDockWidget, PANEL_OBJECT_NAME)
    if panel is None:
        panel = CopilotPanel(main_window)
        main_window.addDockWidget(QtCore.Qt.RightDockWidgetArea, panel)
    panel.show()
    panel.raise_()
    return panel


def _context():
    doc = App.ActiveDocument
    selection = []
    try:
        selection = [obj.Label for obj in Gui.Selection.getSelection()]
    except Exception:
        selection = []
    return {
        "document": doc.Name if doc else None,
        "selection": selection,
    }
