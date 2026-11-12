package de.sweber.encrypted_calendar_app

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * Kalenderauswahl für genau ein Widget. Erscheint beim Hinzufügen des Widgets,
 * über „Widget anpassen“ (langes Drücken) und über das Zahnrad im Widget.
 */
class WidgetConfigActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        widgetId = intent?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        // Abbrechen beim ersten Hinzufügen = Widget wird nicht angelegt
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        title = "Kalender für dieses Widget"

        val snap = WidgetData.load(this)
        val cfg = WidgetPrefs.get(this, widgetId)
        val allKeys = snap.calendars.map { it.key }.toSet()
        val selected = (cfg?.keys ?: snap.defaultKeys ?: allKeys).toMutableSet()
        var holidays = cfg?.holidays ?: snap.defaultHolidays

        val dp = resources.displayMetrics.density
        fun px(v: Int) = (v * dp).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(px(20), px(8), px(20), px(12))
        }
        root.addView(TextView(this).apply {
            text = "Welche Kalender soll dieses Widget zeigen?"
            setPadding(0, 0, 0, px(8))
        })

        if (snap.calendars.isEmpty()) {
            root.addView(TextView(this).apply {
                text = "Noch keine Kalender bekannt – bitte einmal die App öffnen, damit sie ihre Kalender ans Widget übergibt."
                setPadding(0, px(8), 0, px(8))
            })
        }
        for ((source, cals) in snap.calendars.groupBy { it.source }) {
            if (source.isNotEmpty() && snap.calendars.map { it.source }.distinct().size > 1) {
                root.addView(TextView(this).apply {
                    text = source
                    setTypeface(typeface, Typeface.BOLD)
                    textSize = 13f
                    setPadding(0, px(10), 0, px(2))
                })
            }
            for (c in cals) {
                root.addView(CheckBox(this).apply {
                    text = if (c.emoji.isEmpty()) c.name else "${c.emoji}  ${c.name}"
                    isChecked = c.key in selected
                    buttonTintList = ColorStateList.valueOf(c.color)
                    setOnCheckedChangeListener { _, on -> if (on) selected.add(c.key) else selected.remove(c.key) }
                })
            }
        }
        root.addView(CheckBox(this).apply {
            text = "Feiertage anzeigen"
            isChecked = holidays
            setPadding(paddingLeft, px(12), paddingRight, paddingBottom)
            setOnCheckedChangeListener { _, on -> holidays = on }
        })

        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            setPadding(0, px(12), 0, 0)
        }
        buttons.addView(Button(this, null, android.R.attr.borderlessButtonStyle).apply {
            text = "Abbrechen"
            setOnClickListener { finish() }
        })
        buttons.addView(Button(this, null, android.R.attr.borderlessButtonStyle).apply {
            text = "Speichern"
            setOnClickListener {
                WidgetPrefs.put(this@WidgetConfigActivity, widgetId, WidgetConfig(selected, holidays))
                WidgetData.refresh(this@WidgetConfigActivity, widgetId)
                setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
                finish()
            }
        })
        root.addView(buttons)

        setContentView(ScrollView(this).apply { addView(root) })
        window.setLayout((resources.displayMetrics.widthPixels * 0.9).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT)
    }
}
