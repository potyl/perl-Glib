#
# $Header$
#

package Glib::MakeHelper;

our $VERSION = '0.03';

=head1 NAME

Glib::MakeHelper - Makefile.PL utilities for Glib-based extensions

=head1 SYNOPSIS

 eval "use Glib::MakeHelper; 1"
     or complain_that_glib_is_too_old_and_die();
 
 %xspod_files = Glib::MakeHelper->do_pod_files (@xs_files);

 package MY;
 sub postamble {
     return Glib::MakeHelper->postamble_clean ()
          . Glib::MakeHelper->postamble_docs (@main::xs_files)
          . Glib::MakeHelper->postamble_rpms (
                 MYLIB     => $build_reqs{MyLib},
            );
 }

=head1 DESCRIPTION

The Makefile.PL for your typical Glib-based module is huge and hairy, thanks to
all the crazy hoops you have to jump through to get things right.  This module
wraps up some of the more intense and error-prone bits to reduce the amount of
copied code and potential for errors.

=cut

use strict;
use warnings;
use Carp;
use Cwd;

our @gend_pods = ();

=head1 METHODS

=over

=item HASH = Glib::MakeHelper->do_pod_files (@xs_files)

Scan the I<@xs_files> and return a hash describing the pod files that will
be created.  This is in the format wanted by WriteMakefile(). If @ARGV contains
the string --disable-apidoc an empty list will be returned and thus no apidoc 
pod will be generated speeding up the build process.

=cut

sub do_pod_files
{
	return () if (grep /disable[-_]apidoc/i, @ARGV);
	print STDERR "Including ApiDoc pod.\n";

	shift; # package name

	# try to get it from pwd first, then fall back to installed
	# this is so Glib will get associated copy, and everyone else
	# should use the installed glib copy
	eval { require 'ParseXSDoc.pm'; 1; } or require Glib::ParseXSDoc;
	$@ = undef;
	import Glib::ParseXSDoc;

	my %pod_files = ();

	open PARSE, '>build/doc.pl';
	select PARSE;
	my $pods = xsdocparse (@_);
	select STDOUT;
	@gend_pods = ();
	foreach (@$pods)
	{
		my $pod = $_;
		my $path = '$(INST_LIB)';
		$pod = File::Spec->catfile ($path, split (/::/, $_)) . ".pod";
		push @gend_pods, $pod;
		$pod_files{$pod} = '$(INST_MAN3DIR)/'.$_.'.$(MAN3EXT)';
	}
	$pod_files{'$(INST_LIB)/$(FULLEXT)/index.pod'} = '$(INST_MAN3DIR)/$(NAME)::index.$(MAN3EXT)';

	return %pod_files;
}

=item string = Glib::MakeHelper->postamble_clean (@files)

Create and return the text of a realclean rule that cleans up after much 
of the autogeneration performed by Glib-based modules.  Everything in @files
will be deleted, too (it may be empty).

The reasoning behind using this instead of just having you use the 'clean'
or 'realclean' keys is that this avoids you having to remember to put Glib's
stuff in your Makefile.PL's WriteMakefile arguments.

=cut

sub postamble_clean
{
	shift; # package name
"
realclean ::
	-\$(RM_RF) build blib_done perl-\$(DISTNAME).spec ".join(" ", @_)."
";
}

=item string = Glib::MakeHelper->postamble_docs (@xs_files)

NOTE: this is The Old Way.  see L<postamble_docs_full> for The New Way.

Create and return the text of Makefile rules to build documentation from
the XS files with Glib::ParseXSDoc and Glib::GenPod.

Use this in your MY::postamble to enable autogeneration of POD.

This updates dependencies with the list of pod names generated by an earlier
run of C<do_pod_files>.

There is a special Makefile variable POD_DEPENDS that should be set to the
list of files that need to be created before the doc.pl step is run, include
files.

There is also a variable BLIB_DONE which should be used as a dependancy
anywhere a rule needs to be sure that a loadable and working module resides in
the blib directory before running.

=cut

sub postamble_docs
{
	my ($class, @xs_files) = @_;
	return Glib::MakeHelper->postamble_docs_full (XS_FILES => \@xs_files);
}

=item string = Glib::MakeHelper->postamble_docs_full (...)

Create and return the text of Makefile rules to build documentation from
the XS files with Glib::ParseXSDoc and Glib::GenPod.

Use this in your MY::postamble to enable autogeneration of POD.

This updates dependencies with the list of pod names generated by an earlier
run of C<do_pod_files>.

There is a special Makefile variable POD_DEPENDS that should be set to the
list of files that need to be created before the doc.pl step is run, include
files.

There is also a variable BLIB_DONE which should be used as a dependancy
anywhere a rule needs to be sure that a loadable and working module resides in
the blib directory before running.

The parameters are a list of key=>value pairs.  You must specify at minimum
either DEPENDS or XS_FILES.

=over

=item DEPENDS => ExtUtils::Depends object

Most gtk2-perl modules use ExtUtils::Depends to find headers, typemaps,
and other data from parent modules and to install this data for child
modules.  We can find from this object the list of XS files to scan for
documentation, doctype mappings for parent modules, and other goodies.

=item XS_FILES => \@xs_file_names

A list of xs files to scan for documentation.  Ignored if DEPENDS is
used.

=item DOCTYPES => \@doctypes_file_names

List of filenames to pass to C<Glib::GenPod::add_types>.  May be omitted.

=item COPYRIGHT => string

POD text to be inserted in the 'COPYRIGHT' section of each generated page.
May be omitted.

=item COPYRIGHT_FROM => file name

The name of a file containing the POD to be inserted in the 'COPYRIGHT'
section of each generated page.  May be omitted.

=back

=cut

sub postamble_docs_full {
	my $class = shift; # package name
	my %params = @_;

	croak "Usage: $class\->postamble_docs_full (...)\n"
	    . "  where ... is a list of key/value pairs including at the\n"
	    . "  very least one of DEPENDS=>\$extutils_depends_object or\n"
	    . "  XS_FILES=>\@xs_files\n"
	    . "    "
		unless $params{DEPENDS} or $params{XS_FILES};

	my @xs_files = ();
	my @doctypes = ();
	my $add_types = '';
	my $copyright = '';

	if ($params{DOCTYPES}) {
		@doctypes = ('ARRAY' eq ref $params{DOCTYPES})
		          ? @{$params{DOCTYPES}}
		          : ($params{DOCTYPES});
	}

	if (UNIVERSAL::isa ($params{DEPENDS}, 'ExtUtils::Depends')) {
		my $dep = $params{DEPENDS};

		# fetch list of XS files from depends object.
		# HACK ALERT: the older versions of ExtUtils::Depends
		# (<0.2) use a different key layout and don't store enough
		# metadata about the dependencies, so we require >=0.2;
		# however, the older versions don't support import version
		# checking (in fact they don't support version-checking at
		# all), so the "use" test in a Makefile.PL can't tell if
		# it has loaded a new enough version!
		# the rewrite at version 0.200 added the get_dep() method,
		# which we use, so let's check for that.
		unless (defined &ExtUtils::Depends::get_deps) {
			use ExtUtils::MakeMaker;
			warn "ExtUtils::Depends is too old, need at "
			   . "least version 0.2";
			# this is so that CPAN builds will do the upgrade
			# properly.
			WriteMakefile(
				PREREQ_FATAL => 1,
				PREREQ_PM => { 'ExtUtils::Depends' => 0.2, },
			);
			exit 1; # not reached.
		}
		# continue with the excessive validation...
		croak "value of DEPENDS key must be an ExtUtils::Depends object"
			unless UNIVERSAL::isa $dep, 'ExtUtils::Depends';
		croak "corrupt or invalid ExtUtils::Depends instance -- "
		    . "the xs key is "
		    .(exists ($dep->{xs}) ? "missing" : "broken")."!"
			unless exists $dep->{xs}
			   and 'ARRAY' eq ref $dep->{xs};

		# finally, *this* is what we wanted.
		@xs_files = @{$dep->{xs}};

		# fetch doctypes files from the depends' dependencies.
		my %deps = $dep->get_deps;
		foreach my $d (keys %deps) {
			my $f = File::Spec->catfile ($deps{$d}{instpath},
			                             'doctypes');
			#warn "looking for $f\n";
			push @doctypes, $f
				if -f $f;
		}
	} else {
		@xs_files = @{ $params{XS_FILES} };
	}

	if ($params{COPYRIGHT}) {
		$copyright = $params{COPYRIGHT};
	} elsif ($params{COPYRIGHT_FROM}) {
		open IN, $params{COPYRIGHT_FROM} or
			croak "can't open $params{COPYRIGHT_FROM} for reading: $!\n";
		local $/ = undef;
		$copyright = <IN>;
		close IN;
	}

	if ($copyright) {
		# this text has to be escaped for both make and the shell.
		$copyright =~ s/\n/\\n/gm; # collapse to one line.
		$copyright =~ s/"/\"/gm;   # escape double-quotes
		$copyright = "\$\$Glib::GenPod::COPYRIGHT=\"$copyright\";";
	}

	#warn "".scalar(@doctypes)." doctype files\n";
	#warn "".scalar(@xs_files)." xs files\n";
	
	$add_types = "add_types (".join(", ",map {"\"$_\""} @doctypes)."); "
		if @doctypes;

	my $docgen_code = ''
	    . $add_types
	    . ' '
	    . $copyright
	    . ' $(POD_SET) '
	    . 'xsdoc2pod("build/doc.pl", "$(INST_LIB)", "build/podindex");';

	#warn "docgen_code: $docgen_code\n";

	# BLIB_DONE should be set to something we can depend on that will
	# ensure that we are safe to link against an up to date module out
	# of blib. basically what we need to wait on is the static/dynamic
	# lib file to be created. the following trick is intended to handle
	# both of those cases without causing the other to happen.
	my $blib_done;
	# this is very sloppy, because different makes have different
	# conditional syntaxes.
	use Config;
	if ($Config{make} eq 'nmake') {
		warn "loathe nmake.\n";
		$blib_done = "
!If \"\$(LINKTYPE)\" == \"dynamic\"
BLIB_DONE=\$(INST_DYNAMIC)
!ELSE
BLIB_DONE=\$(INST_STATIC)
!ENDIF
";
	} else {
		# assuming GNU Make
		$blib_done = "
ifeq (\$(LINKTYPE), dynamic)
	BLIB_DONE=\$(INST_DYNAMIC)
else
	BLIB_DONE=\$(INST_STATIC)
endif
";
	}

"
BLIB_DONE=
$blib_done

# documentation stuff
build/doc.pl :: Makefile @xs_files
	$^X -I \$(INST_LIB) -I \$(INST_ARCHLIB) -MGlib::ParseXSDoc \\
		-e 'xsdocparse (".join(", ",map {"\"$_\""} @xs_files).")' > \$@

# passing all of these files through the single podindex file, which is 
# created at the same time, prevents problems with -j4 where xsdoc2pod would 
# have multiple instances
@gend_pods :: build/podindex \$(POD_DEPENDS)

build/podindex :: \$(BLIB_DONE) Makefile build/doc.pl
	$^X -I \$(INST_LIB) -I \$(INST_ARCHLIB) -MGlib::GenPod -M\$(NAME) \\
		-e '$docgen_code'

\$(INST_LIB)/\$(FULLEXT)/:
	$^X -MExtUtils::Command -e mkpath \$@

\$(INST_LIB)/\$(FULLEXT)/index.pod :: \$(INST_LIB)/\$(FULLEXT)/ build/podindex
	$^X -e 'print \"\\n=head1 NAME\\n\\n\$(NAME) API Reference Pod Index\\n\\n=head1 PAGES\\n\\n=over\\n\\n\"' \\
		> \$(INST_LIB)/\$(FULLEXT)/index.pod
	$^X -nae 'print \"=item L<\$\$F[1]>\\n\\n\";' < build/podindex >> \$(INST_LIB)/\$(FULLEXT)/index.pod
	$^X -e 'print \"=back\\n\\n\";' >> \$(INST_LIB)/\$(FULLEXT)/index.pod
"
}

=item string = Glib::MakeHelper->postamble_rpms (HASH)

Create and return the text of Makefile rules to manage building RPMs.
You'd put this in your Makefile.PL's MY::postamble.

I<HASH> is a set of search and replace keys for the spec file.  All 
occurences of @I<key>@ in the spec file template perl-$(DISTNAME).spec.in
will be replaced with I<value>.  'VERSION' and 'SOURCE' are supplied for
you.  For example:

 Glib::MakeHelper->postamble_rpms (
        MYLIB     => 2.0.0, # we can work with anything from this up
        MYLIB_RUN => 2.3.1, # we are actually compiled against this one
        PERL_GLIB => 1.01,  # you must have this version of Glib
 );

will replace @MYLIB@, @MYLIB_RUN@, and @PERL_GLIB@ in spec file.  See
the build setups for Glib and Gtk2 for examples.

Note: This function just returns an empty string on Win32.

=cut

sub postamble_rpms
{
	shift; # package name

	return '' if $^O eq 'MSWin32';
	
	my @dirs = qw{$(RPMS_DIR) $(RPMS_DIR)/BUILD $(RPMS_DIR)/RPMS 
		      $(RPMS_DIR)/SOURCES $(RPMS_DIR)/SPECS $(RPMS_DIR)/SRPMS};
	my $cwd = getcwd();
	
	chomp (my $date = `date +"%a %b %d %Y"`);

	my %subs = (
		'VERSION' => '$(VERSION)',
		'SOURCE'  => '$(DISTNAME)-$(VERSION).tar.gz',
		'DATE'    => $date,
		@_,
	);
	
	my $substitute = '$(PERL) -npe \''.join('; ', map {
			"s/\\\@$_\\\@/$subs{$_}/g";
		} keys %subs).'\'';

"

RPMS_DIR=\$(HOME)/rpms

\$(RPMS_DIR)/:
	-mkdir @dirs

SUBSTITUTE=$substitute

perl-\$(DISTNAME).spec :: perl-\$(DISTNAME).spec.in \$(VERSION_FROM) Makefile
	\$(SUBSTITUTE) \$< > \$@

dist-rpms :: Makefile dist perl-\$(DISTNAME).spec \$(RPMS_DIR)/
	cp \$(DISTNAME)-\$(VERSION).tar.gz \$(RPMS_DIR)/SOURCES/
	rpmbuild -ba --define \"_topdir \$(RPMS_DIR)\" perl-\$(DISTNAME).spec

dist-srpms :: Makefile dist perl-\$(DISTNAME).spec \$(RPMS_DIR)/
	cp \$(DISTNAME)-\$(VERSION).tar.gz \$(RPMS_DIR)/SOURCES/
	rpmbuild -bs --nodeps --define \"_topdir \$(RPMS_DIR)\" perl-\$(DISTNAME).spec
";
}

package MY;

=back

=head1 NOTICE

The MakeMaker distributed with perl 5.8.x generates makefiles with a bug that
causes object files to be created in the wrong directory.  There is an override
inserted by this module under the name MY::const_cccmd to fix this issue.

=cut

sub const_cccmd {
	my $inherited = shift->SUPER::const_cccmd (@_);
	return '' unless $inherited;
	use Config;
	# a more sophisticated match may be necessary, but this works for me.
	if ($Config{cc} eq "cl") {
		warn "you are using MSVC... my condolences.\n";
		$inherited .= ' /Fo$@';
	} else {
		$inherited .= ' -o $@';
	}
	$inherited;
}

1;

=head1 AUTHOR

Ross McFarland E<lt>rwmcfa1 at neces dot comE<gt>

hacked up and documented by muppet.

=head1 COPYRIGHT AND LICENSE

Copyright 2003-2004 by the gtk2-perl team

This library is free software; you can redistribute it and/or modify
it under the terms of the Lesser General Public License (LGPL).  For 
more information, see http://www.fsf.org/licenses/lgpl.txt

=cut
