/*
 * $Header$
 */

#include "gperl.h"

#include "ppport.h"

void
_gperl_call_XS (pTHX_ void (*subaddr) (pTHX_ CV *), CV * cv, SV ** mark)
{
	dSP;
	PUSHMARK (mark);
	(*subaddr) (aTHX_ cv);
	PUTBACK;	/* forget return values */
}



void
gperl_croak_gerror (const char * prefix, GError * err)
{
	/* croak does not return, which doesn't give us the opportunity
	 * to free the GError.  thus, we create a copy of the croak message
	 * in an SV, which will be garbage-collected, and free the GError
	 * before croaking. */
	SV * svmsg;
	if (prefix && strlen (prefix)) {
		svmsg = newSV(0);
		sv_catpvf (svmsg, "%s: %s", prefix, err->message);
	} else {
		svmsg = newSVpv (err->message, 0);
	}
	/* don't need this */
	g_error_free (err);
	/* mark it as ready to be collected */
	sv_2mortal (svmsg);
	croak (SvPV_nolen (svmsg));
}


/*
 * taken from pgtk_alloc_temp in Gtk-Perl-0.7008/Gtk/MiscTypes.c
 */
gpointer
gperl_alloc_temp (int nbytes)
{
	dTHR;

	SV * s = sv_2mortal (newSVpv ("", 0));
	SvGROW (s, nbytes);
	memset (SvPV (s, PL_na), 0, nbytes);
	return SvPV (s, PL_na);
}



MODULE = Glib		PACKAGE = Glib

BOOT:
	g_type_init ();
	/* boot all in one go.  other modules may not want to do it this
	 * way, if they prefer instead to perform demand loading. */
	GPERL_CALL_BOOT (boot_Glib__Type);
	GPERL_CALL_BOOT (boot_Glib__Boxed);
	GPERL_CALL_BOOT (boot_Glib__Object);
	GPERL_CALL_BOOT (boot_Glib__Signal);
	GPERL_CALL_BOOT (boot_Glib__MainLoop);
