package com.kronagent.plainly

import android.app.Application
import com.google.firebase.Firebase
import com.google.firebase.FirebaseApp
import com.google.firebase.appcheck.appCheck
import com.google.firebase.appcheck.debug.DebugAppCheckProviderFactory
import com.google.firebase.initialize

class PlainlyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Firebase.initialize(this)
        // Hackathon builds use App Check's debug provider, which the #BuildHybridAI rules accept. The provider would
        // otherwise invent a new secret on every phone (each needing manual registration), so the one secret
        // registered in the console is stored where the provider looks first. A Play-distributed release would use
        // PlayIntegrityAppCheckProviderFactory instead.
        val secret = BuildConfig.APPCHECK_DEBUG_SECRET
        if (secret.isNotBlank()) {
            val key = FirebaseApp.getInstance().persistenceKey
            getSharedPreferences("com.google.firebase.appcheck.debug.store.$key", MODE_PRIVATE).edit()
                .putString("com.google.firebase.appcheck.debug.DEBUG_SECRET", secret).apply()
        }
        Firebase.appCheck.installAppCheckProviderFactory(DebugAppCheckProviderFactory.getInstance())
    }
}
