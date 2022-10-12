######################################################################
#
#  Alma Import
#
#  This plugin imports metadata/documents from Alma MARC XML.
#
#  Part of https://idbugs.uzh.ch/browse/ZORA-976
# 
######################################################################
#
#  Copyright 2022 University of Zurich. All Rights Reserved.
#
#  Martin Brändle
#  Zentrale Informatik
#  Universität Zürich
#  Stampfenbachstr. 73
#  CH-8006 Zürich
#
#  Initial:
#  2022/09/27/mb based on AlephMarc.pm
#
#  Modified:
#  
#
#  The plug-ins are free software; you can redistribute them and/or modify
#  them under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The plug-ins are distributed in the hope that they will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with EPrints 3; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
######################################################################

=pod

=head1 NAME

EPrints::Plugin::Import::AlmaMarc - Plug-in for importing Alma MARCXML 

=head1 DESCRIPTION

This plug-in imports MARCXML data.

The import plug-in contains generic, document type-agnostic methods to read Alma MARC XML.

General functionality:
- treats a MARC record as XML document
- reads the mappings MARC field/subfield --> processing method from configuration
- parses the MARC fields and calls the respective processing method. Saves the return value 
  in $epdata->{fieldname}.
  MARC fields (e.g. 690, keywords) that are repeated are also processed repeatedly.
- supplements data of additional fields such as document type, collection, OA status, 
  copyright statement, abstract, faculty, Primo catalog URL (related_url)
- checks validity of epdata for faculty and thesis examiners

Specific funtionality:
- code which is specific to the ZORA implementation (fields, language codes, ...) is marked 
  with comment "# ZORA specific"


=head1 METHODS

=over 4

=item $plugin = EPrints::Plugin::Import::AlmaMarc->new( %params )

Creates a new Import::AlmaMarc plugin. Should not be called directly, but via $session->plugin.

=cut

package EPrints::Plugin::Import::AlmaMarc;

use strict;
use warnings;
use utf8;

use lib '/usr/local/eprints/perl_cpan/lib/perl5';

use Encode qw(encode decode);
use XML::LibXML;
use LWP::Simple;
use Date::Calc qw(Decode_Date_EU);
use File::Temp qw(tempfile);
use Text::Roman qw(:all);
use Text::Unidecode;

use base 'EPrints::Plugin::Import';

sub new
{
	my( $class, %params ) = @_;

	my $self = $class->SUPER::new( %params );

	$self->{name} = "Alma MARCXML Import";
	$self->{advertise} = 0;
	$self->{visible} = "all";
	$self->{produce} = [ 'dataobj/eprint' ];

	return $self;
}


=item $epdata = $plugin->convert_input( $doc ) 

Main parsing method for MARCXML data. B<$doc> contains the XML tree.

=cut

sub convert_input
{
	my ($plugin, $doc) = @_;
	
	my $epdata = {};
	my $marc_mappings;
	
	my $session = $plugin->{session};
	my $dataset = $session->get_repository->dataset( "eprint" );
	
	# read the configuration and build a hash
	my $marc_mappings_config = $session->get_repository->config( 'marc_import_mappings' );
	
	foreach my $mapping (@$marc_mappings_config)
	{
		my $marcfieldtype = $mapping->{'marcfieldtype'};
		my $marcfield = $mapping->{'marcfield'};
		my $marcsubfield = $mapping->{'marcsubfield'};
		my $fieldname = $mapping->{'fieldname'};
		my $method = $mapping->{'method'};
		my $filter = $mapping->{'filter'};
		
		$marc_mappings->{$marcfieldtype}->{$marcfield}->{$marcsubfield}->{fieldname} = $fieldname;
		$marc_mappings->{$marcfieldtype}->{$marcfield}->{$marcsubfield}->{method} = $method;
		$marc_mappings->{$marcfieldtype}->{$marcfield}->{$marcsubfield}->{filter} = $filter;
	}
	
	# parse the MARC fields and call the associated transformation method
	my $xpc = XML::LibXML::XPathContext->new( $doc );
	$xpc->registerNs( "marc", "http://www.loc.gov/MARC21/slim" );
	
	my @marcrecords = $xpc->findnodes( './marc:record' );
	my $marcrecord = $marcrecords[0];
	
	my @marcfieldnodes = $marcrecord->childNodes();
	
	foreach my $marcfieldnode (@marcfieldnodes)
	{
		if ( $marcfieldnode->nodeType == 1)
		{
			my $marcfieldtype = $marcfieldnode->nodeName();
			
			if ( $marcfieldtype eq 'datafield' )
			{
				my $marcfield = $marcfieldnode->getAttribute( 'tag' );
				
				my $options = {
					ind1 => $marcfieldnode->getAttribute( 'ind1' ),
					ind2 => $marcfieldnode->getAttribute( 'ind2' ),
				};
				
				my @marcsubfieldnodes = $marcfieldnode->childNodes();
				
				foreach my $marcsubfieldnode (@marcsubfieldnodes)
				{
					if ( $marcsubfieldnode->nodeType == 1)
					{
						my $marcsubfield = $marcsubfieldnode->getAttribute( 'code' );
						my $marcvalue = $marcsubfieldnode->textContent();
						# strip leading and trailing spaces
						$marcvalue =~ s/^\s+|\s+$//g;
						
						my $fieldname = $marc_mappings->{$marcfieldtype}->{$marcfield}->{$marcsubfield}->{fieldname};
						my $method = $marc_mappings->{$marcfieldtype}->{$marcfield}->{$marcsubfield}->{method};
						my $filter = $marc_mappings->{$marcfieldtype}->{$marcfield}->{$marcsubfield}->{filter};
						
						if (defined $filter)
						{
							$options->{filter} = $session->get_repository->config( 'marcfilter', $filter ); 
						}
						
						if (defined $method)
						{
							$plugin->{param}->{currentnode} = $marcfieldnode;
							my $value = $plugin->$method( $epdata, $fieldname, $marcvalue, $options );
							if (defined $fieldname && $fieldname ne '')
							{
								# check for correctness of fieldname, temporary field names ending with tmp
								# will be deleted in check_epdata
								if ($dataset->has_field( $fieldname ) || $fieldname =~ /tmp$/)
								{
									$epdata->{$fieldname} = $value if (defined $value);
								}
								else
								{
									print STDERR "AlmaMarc Import: EPrints field $fieldname does not exist\n";
								}
							}
						}
					}
				}
			}
			elsif ( $marcfieldtype eq 'controlfield' )
			{
				my $marcfield = $marcfieldnode->getAttribute( 'tag' );
				
				my $fieldname = $marc_mappings->{$marcfieldtype}->{$marcfield}->{'none'}->{fieldname};
				my $method = $marc_mappings->{$marcfieldtype}->{$marcfield}->{'none'}->{method};
				
				my $marcvalue = $marcfieldnode->textContent();
				
				if (defined $method)
				{
					my $value = $plugin->$method( $epdata, $fieldname, $marcvalue );
					$epdata->{$fieldname} = $value if (defined $value);
				}
			}
			elsif ( $marcfieldtype eq 'leader' )
			{
				my $leader = $marcfieldnode->textContent();
				$plugin->convert_leader( $leader, $epdata );
			}
			else
			{
				print STDERR "AlmaMarc Import: Undefined MARC field type $marcfieldtype\n";
			}
		}
	}
	
	$epdata = $plugin->add_missing_fields( $doc, $epdata );
	$epdata = $plugin->check_epdata( $epdata );
	
	# Uncomment for debugging
	use Data::Dumper;
	print STDERR Dumper($epdata);
	
	return $epdata;
}

=item $epdata = $plugin->add_missing_fields( $doc, $epdata )

Supplements B<$epdata> with additional field data. 
B<$doc> contains the XML tree of the MARC data.

=cut

sub add_missing_fields
{
	my ( $plugin, $doc, $epdata ) = @_;
	
	# ZORA specific
	# depending on type, add dissertation type
	if ( defined $epdata->{type} && $epdata->{type} eq 'dissertation' )
	{
		if ( !defined $epdata->{thesis_subtype} )
		{
			$epdata->{thesis_subtype} = 'monographical';
		}
	}
	
	#  ZORA specific
	if ( defined $epdata->{type} && $epdata->{type} eq 'article' )
	{
		$epdata->{publication} = $epdata->{series};
		$epdata->{series} = undef;
	}
	
	# ZORA specific
	# add the OA type to the data
	$epdata->{oa_status} = 'closed';
	
	# ZORA specific
	# add the copyright statement
	$epdata->{copyright}->[0] = 'offen';
	
	return $epdata;
}

=item $epdata = $plugin->check_epdata( $epdata )

Does a few checks on validity of B<$epdata> for authors and examiners

=cut

sub check_epdata
{
	my ( $plugin, $epdata ) = @_;
	
	# Temporary creator data
	if ( defined $epdata->{creatorstmp} && defined $epdata->{creators} )
	{
		foreach my $tmpcreator (@{$epdata->{creatorstmp}})
		{
			my $family = $tmpcreator->{name}->{family};
			my $given = $tmpcreator->{name}->{given};
			
			my $check = 1;
			
			foreach my $creator (@{$epdata->{creators}})
			{
				$check = 0 if ($creator->{name}->{family} eq $family && $creator->{name}->{given} =~ /^\Q$given/);
			}
			
			push @{$epdata->{creators}}, $tmpcreator if $check;
		}
	}
	
	delete $epdata->{creatorstmp};
			
	# Temporary examiner data
	if ( defined $epdata->{examinerstmp} && defined $epdata->{examiners} )
	{
		foreach my $tmpexaminer (@{$epdata->{examinerstmp}})
		{
			my $family = $tmpexaminer->{name}->{family};
			my $given = $tmpexaminer->{name}->{given};
			
			my $check = 1;
			
			foreach my $examiner (@{$epdata->{examiners}})
			{
				$check = 0 if ($examiner->{name}->{family} eq $family && $examiner->{name}->{given} =~ /^\Q$given/);
			}
			
			push @{$epdata->{examiners}}, $tmpexaminer if $check;
		}
	}
	
	delete $epdata->{examinerstmp};
	
	# ZORA specific - edited scientific work with temporary editor data. Also creators are then editors
	if ($epdata->{type} eq 'edited_scientific_work')
	{
		if (defined $epdata->{editorstmp})
		{
			foreach my $tmpeditor (@{$epdata->{editorstmp}})
			{
				my $family = $tmpeditor->{name}->{family};
				my $given = $tmpeditor->{name}->{given};
			
				my $check = 1;
				
				if (defined $epdata->{editors})
				{
					foreach my $editor (@{$epdata->{editors}})
					{
						$check = 0 if ($editor->{name}->{family} eq $family && $editor->{name}->{given} =~ /^\Q$given/);
					}
				}
			
				push @{$epdata->{editors}}, $tmpeditor if $check;
			}
			
			delete $epdata->{editorstmp};
		}
		
		if (defined $epdata->{creators})
		{
			foreach my $creator (@{$epdata->{creators}})
			{
				my $family = $creator->{name}->{family};
				my $given = $creator->{name}->{given};
			
				my $check = 1;
				
				if (defined $epdata->{editors})
				{
					foreach my $editor (@{$epdata->{editors}})
					{
						$check = 0 if ($editor->{name}->{family} eq $family && $editor->{name}->{given} =~ /^\Q$given/);
					}
				}
			
				push @{$epdata->{editors}}, $creator if $check;
			}
			
			delete $epdata->{creators};
		}
	}
	
	# # ZORA specific - distinguish between monograph and edited scientific work
	my $count_creators = 0;
	my $count_editors = 0;
	$count_creators = scalar( @{$epdata->{creators}} ) if (defined $epdata->{creators});
	$count_editors = scalar( @{$epdata->{editors}} ) if (defined $epdata->{editors});
	
	if ($count_editors > 0 && $count_creators == 0)
	{
		$epdata->{type} = 'edited_scientific_work';
	}
	
	return $epdata;
}

=item $value = $plugin->direct( $epdata, $fieldname, $marcvalue, $opt )

Direct conversion of any MARC field value to an epdata value.

=cut 

sub direct
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value = $marcvalue;
	
	return $value;
}

=item $value = $plugin->marc2{field}( $epdata, $fieldname, $marcvalue, $opt )

Processing methods for MARC fields.
B<$epdata>: Current epdata hash, may be needed for multiple MARC field occurences.
B<$fieldname>: EPrints field name. If empty, the method itself must set $epdata.
B<$marcvalue>: Raw MARC field value to be processed.
B<$opt>: MARC field options, e.g. ind1, ind2.

See list of methods in configuration, and specific code below

=cut

#
# ALMA system number --> Primo back link
#
sub marc2systemnumber
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;

	$epdata->{source} = "SLSP:alma" . $marcvalue;

	my $value = $plugin->create_primo_link( $marcvalue );
	
	return $value;
}

#
# Language (language_mult) and date
#
sub marc0082language
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;
	my $lang;
	
	# date
	my $code_year = substr( $marcvalue,6,1 );
	
	if ($code_year eq 's')
	{
		my $date = substr( $marcvalue,7,4 );
		$epdata->{date} = $date;
	}
	
	# language
	$lang = substr( $marcvalue,35,3 ); 
	$lang = $plugin->transform_language( $lang );
	$value = $plugin->marc2multiple( $epdata, $fieldname, $lang );
	
	return $value;
}

# 
# ISBN
#
sub marc2isbn
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	$marcvalue =~ s/([0123456789X-]+)(.*)/$1/g;

	my $value = $marcvalue;
	
	return $value;
}

# 
# ISSN
#
sub marc2issn
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	$marcvalue =~ s/([0123456789X-]+)(.*)/$1/g;
	
	if (defined $epdata->{issn} && $epdata->{issn} ne $marcvalue)
	{
		$epdata->{suggestions} .= "\nWarning: Conflict between ISSN in data field 022_a (" . $epdata->{issn} . 
			") and data field 490_x (" . $marcvalue . ")";
		return;
	}
	
	my $value = $marcvalue;
	
	return $value;
}

# 
# DOI / PMID
#
sub marc2doi_pmid
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;

	return if ( $opt->{ind1} ne '7');
	
	my $marc024_2_value = $plugin->get_marc_subfield( '2' );
	
	# ZORA specific
	if ($marc024_2_value eq 'pmid')
	{
		$epdata->{pubmedid} = $marcvalue;
	}
	
	# ZORA specific
	if ($marc024_2_value eq 'doi')
	{
		$epdata->{doi} = $marcvalue;
	}
	
	return;
}

#
# Language (multilang)
#
sub marc0412language
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $lang = $plugin->transform_language( $marcvalue );
	my $value = $plugin->marc2multiple( $epdata, $fieldname, $lang );
	
	return $value;
}

#
# DDC
#
sub marc2dewey
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;

	my $value = [];

	if ( defined $epdata->{dewey} )
	{
		$value = $epdata->{dewey};
	}

	return $value if ($marcvalue !~ /^[0123456789]/ );
	
	# ZORA specific
	my $dewey = "ddc" . substr( $marcvalue,0,2 ) . "0";
	
	my $noduplicate = 1;
	foreach my $entry (@$value)
	{
		$noduplicate = 0 if ($entry eq $dewey);
	}
	
	push @$value, $dewey if ($noduplicate);
	
	return $value;
}


#
# Corporate contributors
#
sub marc2corpcreators
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;

	my $value;
	
	# remove trailing punctuation characters
	$marcvalue =~ s/[[:punct:]]+$//g;
	
	$value = $plugin->marc2multiple( $epdata, $fieldname, $marcvalue );
	
	return $value;
}


#
# Event title
#
sub marc2event_title
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;
	
	my $value_number = $plugin->get_marc_subfield( 'n' );
	
	if (defined $value_number)
	{
		$value = $value . ' ' . $marcvalue;
	}
	else
	{
		$value = $marcvalue;
	}
	
	return $value;
}


#
# Event date
#
sub marc2event_date
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $startvalue;
	my $endvalue;
	my $event_date_start;
	my $event_date_end;

	if ($marcvalue =~ /-/)
	{
		($startvalue, $endvalue) = split( /-/, $marcvalue );
	}
	else
	{
		$startvalue = $marcvalue;
		$endvalue = $marcvalue;
	}
	
	if (defined $startvalue)
	{
		# remove unwanted characters and leading spaces
		$startvalue =~ s/:|\)|\(//g;
		$startvalue =~ s/^\s+|\s+$//g;
		
		# is there only a year value? otherwise try to parse
		if ($startvalue =~ /\d{4}/)
		{
			$event_date_start = $startvalue . "-01-01"; 
		}
		else
		{ 
			my ($year, $month, $day) = Decode_Date_EU( $startvalue );
			$event_date_start = $year . "-" . sprintf( "%02d", $month ) . "-" . sprintf( "%02d", $day );
		}
		
		$epdata->{event_start} = $event_date_start;
	};
	
	if (defined $endvalue)
	{
		# remove unwanted characters and leading spaces
		$endvalue =~ s/:|\)|\(//g;
		$endvalue =~ s/^\s+|\s+$//g;
		
		# is there only a year value? otherwise try to parse
		if ($endvalue =~ /\d{4}/)
		{
			$event_date_end = $endvalue . "-01-01"; 
		}
		else
		{
			my ($year, $month, $day) = Decode_Date_EU( $endvalue );
			$event_date_end = $year . "-" . sprintf( "%02d", $month ) . "-" . sprintf( "%02d", $day );
		}
		
		$epdata->{event_end} = $event_date_end;
	};
	
	return;
}

#
# Title
#
sub marc2title
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;
	
	if (defined $epdata->{title})
	{
		$value = $epdata->{title} . " : " . $marcvalue;
	}
	else
	{
		$value = $marcvalue;
	}
	
	$value = $plugin->clean_title( $value );
	
	return $value;
}

#
# Creator or Editor (245_c)
#
sub marc245c2person
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;
	my $family_guess;
	my $given_guess;
	
	my $fieldnametmp = 'creatorstmp';
	
	# ignore what is after the ; 
	if ( $marcvalue =~ /(.*?)\s?;\s(.*)$/ )
	{
		$marcvalue = $1;
	}
	
	# apply some filters (gathered from content analysis)
	$marcvalue = $plugin->apply_filters( $marcvalue, $opt->{filter} );
	
	# detect editors
	my $editor_filters = $plugin->{session}->get_repository->config( 'marcfilter', 'editors' );
	
	foreach my $filter (@$editor_filters)
	{
		if ($marcvalue =~ /$filter/)
		{
			$marcvalue =~ s/$filter//g;
			$epdata->{type} = 'edited_scientific_work';
			$fieldnametmp = 'editorstmp';
		}
	}

	$marcvalue =~ s/in\scollaboration\swith/and/g;
	
	# their may be many different separators for person names
	my @persons = split( /,\s|\sund\s|\sand\s|\/|\s\|\s|\s\&\s/, $marcvalue );
	
	# remove honorific titles
	my $honorific = $plugin->{session}->get_repository->config( 'marchonorific' );
	
	# remove << >> and shift name parts
	my $shiftnameparts = $plugin->{session}->get_repository->config( 'marcshiftnameparts' );
	
	foreach my $person (@persons)
	{
		$person = $plugin->apply_filters( $person, $honorific );
		$person =~ s/^\s+|\s+$|\.$//g;
		
		next if ($person eq '');
		
		my $match = 0;
	
		foreach my $shiftnamepart (@$shiftnameparts)
		{
			next if $match;
			if ($person =~ /$shiftnamepart/i)
			{
				$given_guess = $1;
				$family_guess = $2;
				$match = 1;
			}
		}
		
		if (!$match)
		{
			my $pos = rindex( $person, ' ' );
			$family_guess = substr( $person, $pos+1 );
			$given_guess = substr( $person, 0, $pos );
		}
		
		my ($family, $given) = $plugin->clean_name( $family_guess, $given_guess );
		
		$value = $plugin->marc2name( $epdata, $fieldnametmp, $family, $given, undef );
	}
	
	$epdata->{$fieldnametmp} = $value;
	
	return;
}

#
# Alternative titles
#
sub marc2othertitles
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;
	
	my $othertitle = $plugin->clean_title( $marcvalue );
	
	if ( defined $epdata->{otthertitles} )
	{
		$value = $epdata->{otthertitles} . "\n" . $othertitle;
	}
	else
	{
		$value = $othertitle;
	}
	
	return $value;
}

#
# Place of publication
#
sub marc2place
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	$marcvalue = $plugin->apply_filters( $marcvalue, $opt->{filter} );
	$marcvalue = $plugin->clean_title( $marcvalue );
	
	return $marcvalue;
}

#
# Publisher
#
sub marc2publisher
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	$marcvalue = $plugin->apply_filters( $marcvalue, $opt->{filter} );
	$marcvalue = $plugin->clean_title( $marcvalue );
	
	return $marcvalue;
}

#
# Date
#
sub marc2date
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;
	
	my $roman = 0;
	$roman = 1 if ($marcvalue =~ /[MDCLXVI]+/);
		
	if ($roman)
	{
		$marcvalue =~ s/[^MDCLXVI]//g;
		$marcvalue = Text::Roman::roman2int( $marcvalue );
	}
	else
	{
		$marcvalue =~ s/\D//g;
	}
	
	if ( defined $marcvalue && $marcvalue > 2099 )
	{
		$epdata->{suggestions} .= "\nWarning: Typo in date: " . $marcvalue;
	}
	
	if (defined $epdata->{date})
	{
		if ($marcvalue ne $epdata->{date})
		{
			$value = $epdata->{date};
			$epdata->{suggestions} .= "\nWarning: Conflict between date in control field 008 (" . $epdata->{date} . 
				") and data field 260_c or 502_d (" . $marcvalue . ")";
		}
	}
	else
	{
		$value = $marcvalue;
	}
	
	return $value;
}

#
# Pages
#
sub marc2pages
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;
	
	# page range?
	if ( $marcvalue =~ /^S\.\s?\d+?-\d+/ || $marcvalue =~ /^Bl\.\s?\d+?-\d+/ || 
	     $marcvalue =~ /^Blatt\s?\d+?-\d+/ || $marcvalue =~ /^Blätter\s?\d+?-\d+/ ||
	     $marcvalue =~ /^Seiten\s?\d+?-\d+/ )
	{
		$marcvalue =~ s/^S\.\s?//g;
		$marcvalue =~ s/^Bl\.\s?//g;
		$marcvalue =~ s/^Blatt\s?//g;
		$marcvalue =~ s/^Blätter\s?//g;
		$marcvalue =~ s/^Seiten\s?//g;
		
		$epdata->{pagerange} = $marcvalue;
		my ($page_begin) = $marcvalue =~ s/(\d+?)-/$1/g;
		my ($page_end) = $marcvalue =~ s/-(\d+?)/$1/g; 
		
		$value = $page_end - $page_begin + 1;
	}
	
	else
	{
		$marcvalue = $plugin->apply_filters( $marcvalue, $opt->{filter} );
		
	    my @pages_values = split( /,/, $marcvalue );
	    
	    my $total_pages = 0;
	    
	    foreach my $page_value (@pages_values)
	    {
	    	$page_value =~ s/^\s+|\s+$//g; 
	    	
	    	if (defined $page_value && $page_value =~ /(\d+)/)
	    	{
	    		$total_pages += $1;
	    	}
	    	elsif (defined $page_value && Text::Roman::isroman( $page_value )) 
	    	{
				# might be Roman value
				my $arabic = Text::Roman::roman2int( $page_value );
				$total_pages += $arabic if defined $arabic;
	    	}
	    	else
	    	{}
	    }
	    $value = $total_pages;
	}
	
	return $value;
}
#
# Series
#
sub marc2series
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	$marcvalue = $plugin->apply_filters( $marcvalue, $opt->{filter} );
	
	return $marcvalue;
}
#
# Volume
#
sub marc2volume
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	return $marcvalue;
}

#
# Note
# 
sub marc2note
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value = $epdata->{$fieldname};
	if ( defined $value )
	{
		$value .= "\n" . $marcvalue;
	}
	else
	{
		$value = $marcvalue;
	}
	
	return $value;
}

#
# Examiners (502a), these will be stored to a temporary field and later compared with
# examiners parsed from field 
# ZORA specific: examination of thesis part
#
sub marc5022examiners
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;
	my $thesis_part;
	my $examiners_part;
	my $family_guess;
	my $given_guess;
	
	# Split into thesis and examiners part. Usual format is (by example):
	# Diss. phil. Univ. Zürich, 2003. - Ref.: Gudela Grote ; Korref.: François Stoll
	# there are also cases without Korref. or with (wrong!) Koref.

	if ( $marcvalue =~ /^(.*?)\.\s-\s(.*?)$/ )
	{
		$thesis_part = $1;
		$examiners_part = $2;
	}
	else
	{
		$thesis_part = $marcvalue;
	}
	
	#
	# Parse the thesis part
	#
	if (defined $thesis_part )
	{
		# try to extract publication year
		# - first date in case of range
		# - standard 4-digit year
		my $pubyear;
		
		if ( $thesis_part =~ /.*?(\d{4})\-\d{4}$/ || 
		     $thesis_part =~ /.*?(\d{4})\/\d{4}$/ ||
		     $thesis_part =~ /.*?(\d{4})$/ ||
		     $thesis_part =~ /.*?(\d{4})\-\d{2}$/ )
		{
			$pubyear = $1;
		}
		else
		{}
		
		if ( defined $epdata->{date} )
		{
			if ( defined $pubyear && $pubyear ne $epdata->{date} )
			{
				$epdata->{suggestions} .= "\nWarning: Conflict between date in control field 008 (" . $epdata->{date} . 
				") and extracted data from field 502_a (" . $pubyear . ")";
			}
		}
		else
		{
			$epdata->{date} = $pubyear if (defined $pubyear);
		}
		
		# try to extract type of thesis and institution using a set of rules from configuration
		my $thesis_rules = $plugin->{session}->get_repository->config( 'marcdissertationnote' );
		
		my $match = 0;
		foreach my $thesis_rule (@$thesis_rules)
		{
			next if $match;
			my $pattern = decode('utf-8', $thesis_rule->{pattern});
			
			if ($thesis_part =~ /$pattern/)
			{
				$match = 1;
				$epdata->{type} = $thesis_rule->{type};
				$epdata->{thesis_subtype} = $thesis_rule->{subtype} if ($thesis_rule->{subtype} ne '');
				my $institution_guess = $1;
				if ($thesis_rule->{institution} eq 'guess' && !defined $epdata->{institution} && defined $institution_guess)
				{
					$epdata->{institution} = $plugin->clean_institution( $institution_guess );
				}
				elsif (!defined $epdata->{institution})
				{
					$epdata->{institution} = $thesis_rule->{institution};
				}
				
				$epdata->{faculty} = $thesis_rule->{faculty} if ($thesis_rule->{faculty} ne '');
			}
		}
	}
	
	#
	# Parse the examiners part
	#
	if ( defined $examiners_part )
	{
		$examiners_part = $plugin->apply_filters( $examiners_part, $opt->{filter} );
		
		my @examiners = split( /\s;\s|\s\.\s-\s/, $examiners_part );
		
		my $shiftnameparts = $plugin->{session}->get_repository->config( 'marcshiftnameparts' );		
	
		foreach my $examiner (@examiners)
		{
			my $match = 0;
	
			foreach my $shiftnamepart (@$shiftnameparts)
			{
				next if $match;
				if ($examiner =~ /$shiftnamepart/i)
				{
					$given_guess = $1;
					$family_guess = $2;
					$match = 1;
				}
			}
		
			if (!$match)	
			{
				my $pos = rindex( $examiner, ' ' );
				$family_guess = substr( $examiner, $pos+1 );
				$given_guess = substr( $examiner, 0, $pos );
			}
			
			my ($family, $given) = $plugin->clean_name( $family_guess, $given_guess );
			
			$value = $plugin->marc2name( $epdata, $fieldname, $family, $given, undef);
		}
	}
	
	return $value;
}

#
# Thesis (degree) type 
#
sub marc2degreetype
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;

	my $session = $plugin->{session};
	my $degreetypemap = $session->get_repository->config( 'marcdegreetypemap' );
	
	if (defined $degreetypemap->{$marcvalue})
	{
		$value = $degreetypemap->{$marcvalue};
	}
	
	return $value;
}

#
# Document type from Genre
#
sub marc655a2type
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;
	
	my $session = $plugin->{session};
	my $genre2typemap = $session->get_repository->config( 'marcgenre2typemap' );
	
	my $type = $epdata->{type};
	
	if (!defined $type)
	{
		if (defined $genre2typemap->{$marcvalue})
		{
			$value = $genre2typemap->{$marcvalue};
		}
	}
	else
	{
		if ($type ne 'dissertation' && $type ne 'masters_thesis' && $type ne 'habilitation')
		{
			$value = $genre2typemap->{$marcvalue};
		}
	}
	
	return $value;
}

#
# Institution
# ZORA specific
#
sub marc2institution
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;
	
	if ( $marcvalue =~ /Universität\sZürich/ || $marcvalue =~ /Vetsuisse-Fakultät\sZürich/ || $marcvalue =~ /^Zürich/ || 
	     $marcvalue =~ /Universtität\sZürich/ )
	{
		$value = "University of Zurich";
	}
	else
	{
		if (defined $epdata->{$fieldname} )
		{
			$value = $epdata->{$fieldname} . " / " . $marcvalue;
		}
		else
		{
			$value = $marcvalue;
		}
	}
	
	return $value;
}

#
# Access
# ZORA specific  (currently not done)
#
sub marc2access
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	return;
}

#
# Funding note
#
sub marc2funding
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $funder_name;
	my $award_title;
	my $award_number;
	
	# ZORA specific
	my @funding_references;
	my $funding_reference = $epdata->{funding_reference};
	
	if (defined $funding_reference) 
	{
		@funding_references = @$funding_reference;
	}
	
	if ($marcvalue =~ /,\sproject/)
	{
		($funder_name,$award_title) = split( /,\sproject\s/, $marcvalue );
		$funder_name =~ s/^\s+|\s+$//g;
		$award_title =~ s/^\s+|\s+$|\"//g;
	}
	else
	{
		$funder_name = $marcvalue;
		$award_title = '';
	}
	
	$award_number = $plugin->get_marc_subfield( 'c' );
	
	# ZORA specific
	push @funding_references, {
		funder_name => $funder_name,
		funder_identifier => '',
		funder_type => '',
		funding_stream => '',
		award_number => $award_number,
		award_uri => '',
		award_title => $award_title,
	};
	
	$epdata->{funding_reference} = [ @funding_references ];
	
	return;
}

#
# Keywords, person
#
sub marc2personkeywords
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $family_guess;
	my $given_guess;
	
	if ( $marcvalue =~ /^(.*?),\s(.*)/ )
	{
		$family_guess = $1;
		$given_guess = $2;
	}
	else
	{
		$family_guess = $marcvalue;
		$given_guess = '';
	}
	
	my ($family, $given) = $plugin->clean_name( $family_guess, $given_guess );
	
	my $name = $given . ' ' . $family;
	$name =~ s/^\s+|\s+$//g;
	
	my $value = $plugin->check_keywords( $epdata, $fieldname, $name );
	
	return $value;
}

#
# Keywords, general
#
sub marc2keywords
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	return if ( $opt->{ind1} eq 'u');
	
	# apply some filters (gathered from content analysis)
	$marcvalue = $plugin->apply_filters( $marcvalue, $opt->{filter} );
	
	my $keyword_value = $plugin->clean_title( $marcvalue );
	
	# capitalize each word
	$keyword_value = lc($keyword_value);
	$keyword_value =~ s/(^| )(\p{Punct}*)(\w)/$1$2\U$3/g;
	
	my $value = $plugin->check_keywords( $epdata, $fieldname, $keyword_value);
	
	return $value;
}

#
# Keywords, 690 d
#
sub marc690d2keywords
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	# apply some filters (gathered from content analysis)
	$marcvalue = $plugin->apply_filters( $marcvalue, $opt->{filter} );
	
	my $keyword_value = $plugin->clean_title( $marcvalue );
	
	# capitalize each word
	$keyword_value = lc($keyword_value);
	$keyword_value =~ s/(^| )(\p{Punct}*)(\w)/$1$2\U$3/g;
	
	my $value = $plugin->check_keywords( $epdata, $fieldname, $keyword_value);
	
	return $value;
}

#
# Field 773 Host Item Entry 
# ZORA specific because of eprint types
#
sub marc2hostitementry
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	# control subfield
	my $marc_773_7 = $plugin->get_marc_subfield( '7' );
	# edition
	my $marc_773_b = $plugin->get_marc_subfield( 'b' );
	# place, publisher, date of publication
	my $marc_773_d = $plugin->get_marc_subfield( 'd' );
	# related parts (volume, number, pages), repeating
	my $marc_773_g = $plugin->get_marc_subfield( 'g' );
	# ISSN
	my $marc_773_x = $plugin->get_marc_subfield( 'x' );
	# ISBN
	my $marc_773_z = $plugin->get_marc_subfield( 'z' );
	
	my $type = $epdata->{type};
	
	if (defined $marc_773_7 && defined $type)
	{
		if ($marc_773_7 eq 'nnas' && $type eq "article")
		{
			$epdata->{publication} = $marcvalue;
		}
		elsif ($marc_773_7 eq 'nnas' && $type !~ /book_section||newspaper_article/ )
		{
			$epdata->{series} = $marcvalue;
		}
		elsif ( $marc_773_7 eq 'nnab' && $type eq 'book_section' )
		{
			$epdata->{series} = $marcvalue;
		}
		elsif ( $marc_773_7 eq 'nnaa' && $type eq 'book_section' )
		{
			$epdata->{book_title} = $marcvalue;
		}
	}
	else
	{
		if ($type eq 'book_section')
		{
			my @parts = split(/,/, $marcvalue);
			
			if (scalar @parts == 1)
			{
				$epdata->{book_title} = $parts[0];
			}
			elsif (scalar @parts == 2)
			{
				if ($parts[0] =~ /\.\sBand|\.\sBd|\.\sVol/ )
				{
					my ($series, $rest) = split(/\.\s/, $parts[0]);
					$epdata->{series} = $series;
				}
				else
				{
					$epdata->{series} = $parts[0];
				}
				
				$epdata->{book_title} = $parts[1];
			}
			
		}
		elsif ($type eq "newspaper_article")
		{
			$epdata->{newspaper_title} = $marcvalue;
		}
	}
	
	# edition
	if (defined $marc_773_b)
	{

		if (defined $epdata->{note} )
		{
			$epdata->{note} .= "\n" . $marc_773_b;
		}
		else
		{
			$epdata->{note} = $marc_773_b;
		}
	}
	
	# place, publisher, date of publication 
	if (defined $marc_773_d)
	{
		my ($place_of_pub,$publisher) = split( /\s:\s/, $marc_773_d );
		$publisher =~ s/,\s\d4-?$//;
		
		if (!defined $epdata->{place_of_pub})
		{
			$epdata->{place_of_pub} = $place_of_pub;
		}
		else
		{
			if ($epdata->{place_of_pub} ne $place_of_pub)
			{
				$epdata->{suggestions} .= "\nWarning: Conflict between publisher location in data field 260_a (" . $epdata->{place_of_pub} . 
					") and data field 773_d (" . $place_of_pub . ")";
			}
		}
		
		if (!defined $epdata->{publisher})
		{
			$epdata->{publisher} = $publisher;
		}
		else
		{
			if ($epdata->{publisher} ne $publisher)
			{
				$epdata->{suggestions} .= "\nWarning: Conflict between publisher location in data field 260_b (" . $epdata->{publisher} . 
					") and data field 773_d (" . $publisher . ")";
			}
		}
	}
	
	# related parts (volume, number, pages), repeating
	if (defined $marc_773_g)
	{
		my $rest;
		my $pagerange;
		my $pubyear;
		my $volume;
		my $issue_number;
		my @marc_773_g_array;
		
		if (ref($marc_773_g) eq "ARRAY")
		{
			 @marc_773_g_array = @$marc_773_g;
		}
		else
		{
			push @marc_773_g_array, $marc_773_g;
		}
		
		foreach my $marc_773_g_value (@marc_773_g_array)
		{
			if ($marc_773_g_value =~ /^yr:/)
			{
				$pubyear = $marc_773_g_value;
				$pubyear =~ s/^yr://;
			}
			elsif ($marc_773_g_value =~ /^vl:/)
			{
				$volume = $marc_773_g_value;
				$volume =~ s/^vl://;
				$epdata->{volume} = $volume;
			}
			elsif ($marc_773_g_value =~ /^no:/)
			{
				$issue_number = $marc_773_g_value;
				$issue_number =~ s/^no://;
				$epdata->{number} = $issue_number;
			}
			else
			{
				# field has free form, difficult to parse
				my @parts_773_g = split(/,/, $marc_773_g_value);

				foreach my $part_773_g (@parts_773_g)
				{
					$part_773_g = lc($part_773_g);
					$part_773_g =~ s/^\s+|\s+$//g;
					if ($part_773_g =~ /^s\.|^seiten|^pages|p\./)
					{
						($rest,$pagerange) = split(/\s/, $part_773_g);
						$epdata->{pagerange} = $pagerange;
					}
					elsif ($part_773_g =~ /\(\d4\)/)
					{
						# could be combined part
						($rest,$pubyear) = split(/\(/, $part_773_g);
						$pubyear =~s/\)//g;
						
						if ($rest =~ /No\.|Heft/)
						{
							($rest,$issue_number) = split(/No\.\s|Heft\s/, $rest);
							$epdata->{number} = $issue_number;
							$rest =~ s/No\.//g;
							$rest =~ s/^\s+|\s+$//g;
						}
						
						if ($rest =~ /Bd\.|Band|Volume|Vol\./)
						{
							($rest,$volume) = split(/Bd\.\s|Band\s|Volume\s|Vol\.\s/, $rest);
							$epdata->{volume} = $volume;
						}
					}
					elsif ($part_773_g =~ /^\d4$/)
					{
						# could be single year part
						$pubyear = $part_773_g;
					}
					elsif ($part_773_g =~ /Bd\.|Band|Volume|Vol\./)
					{
						$volume = $part_773_g;
						$volume =~ s/Bd\.\s|Band\s|Volume\s|Vol\.\s//g;
						$epdata->{volume} = $volume;
					}
					elsif ($part_773_g =~ /No\.|Heft/)
					{
						$issue_number = $part_773_g;
						$issue_number =~ s/No\.\s|Heft\s//g;
						$epdata->{number} = $issue_number;
					}
					else
					{}
				}
			}
			
			if (!defined $epdata->{date} && defined $pubyear)
			{
				$epdata->{date} = $pubyear;
			}
			elsif (defined $pubyear && $epdata->{date} ne $pubyear)
			{
				$epdata->{suggestions} .= "\nWarning: Conflict between date in control field 008 (" . $epdata->{date} . 
					") and extracted data from 773_g (" . $pubyear . ")";
			}
		}
	}
	
	# ISSN
	if (defined $marc_773_x)
	{
		if (!defined $epdata->{issn})
		{
			$epdata->{issn} = $marc_773_x;
		}
		else
		{
			my $issn_short = $epdata->{issn};
			my $marc_773_x_short = $marc_773_x;
			$issn_short =~ s/-//g;
			$marc_773_x_short =~ s/-//g;
			
			if ($issn_short ne $marc_773_x_short)
			{
				$epdata->{suggestions} .= "\nWarning: Conflict between ISSN in data field 022_a (" . $epdata->{issn} . 
					") and data field 773_x (" . $marc_773_x . ")";
			}
		}
	}
	
	# ISBN
	if (defined $marc_773_z)
	{
		if (!defined $epdata->{isbn})
		{
			$epdata->{isbn} = $marc_773_z;
		}
		else
		{
			my $isbn_short = $epdata->{isbn};
			my $marc_773_z_short = $marc_773_z;
			$isbn_short =~ s/-|\s//g;
			$marc_773_z_short =~ s/-|\s//g;
			
			if ($isbn_short ne $marc_773_z_short)
			{
				$epdata->{suggestions} .= "\nWarning: Conflict between ISBN in data field 020_a (" . $epdata->{isbn} . 
					") and data field 773_z (" . $marc_773_z . ")";
			}
		}
	}
	
	return;
}

#
# URL
#
sub marc2url
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $value;

	# ZORA specific	
	# exclude ZORA DOIs
	return if ( $marcvalue =~ /10\.5167/ );
	
	# ZORA specific	
	# exclude ZORA URLs
	return if ( $marcvalue =~ /www\.zora\.uzh.ch/ );
	
	# exclude URLs that are already available via DOI
	if (defined $epdata->{doi})
	{
		my $doi = $epdata->{doi};
		return if ( $marcvalue =~ /$doi/ );
	}
	
	my $url_type_mappings = $plugin->{session}->get_repository->config( 'url_856u_type_map' );
	
	(my $url_domain = $marcvalue) =~ s/https?:\/\/(.*?)\/.*/$1/;
	
	my $related_url_type = 'pub';
	if (defined $url_type_mappings->{$url_domain})
	{
		$related_url_type = $url_type_mappings->{$url_domain};
	}
	
	push @$value, 
	{ 
		type => $related_url_type,
		url => $marcvalue,
	};
	
	return $value;
}

#
# Persons
#
sub marc2person
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $session = $plugin->{session};
	
	my $relatormap = $session->get_repository->config( 'marcpersonrelatormap' );
	
	my $marcperson4_value = $plugin->get_marc_subfield( '4' );
	my $marcpersone_value = $plugin->get_marc_subfield( 'e' );
	
	# default is creators
	$fieldname = "creators";
	if (defined $marcpersone_value && defined $relatormap->{$marcpersone_value})
	{
		$fieldname = $relatormap->{$marcpersone_value};
	}
	if (defined $marcperson4_value && defined $relatormap->{$marcperson4_value})
	{
		$fieldname = $relatormap->{$marcperson4_value};
	}
	
	# apply some filters (gathered from content analysis)
	$marcvalue = $plugin->apply_filters( $marcvalue, $opt->{filter} );
	$marcvalue =~ s/^\s+|\s+$|\.$//g;
	
	# extract family and given name
	my ($family,$given) = $plugin->get_person_names( $marcvalue, ',\s' );
	
	# extract ORCID iD
	my $orcid;
	my $marcperson0_value = $plugin->get_marc_subfield( '0' );
	if (defined $marcperson0_value && $marcperson0_value =~ /^\(orcid\)/ )
	{
		$marcperson0_value =~ s/\(orcid\)//g;
		$orcid = $marcperson0_value;
	}
	
	my $value = $plugin->marc2name( $epdata, $fieldname, $family, $given, $orcid);
	
	$epdata->{$fieldname} = $value;
	
	return;
}


#
# Examiners (900a) or thesis note
# 
sub marc9002examiners
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	my $session = $plugin->{session};
	
	if ($opt->{ind1} eq '1' || $opt->{ind1} eq '6')
	{
		$fieldname = 'examiners';
		
		my ($family, $given) = $plugin->get_person_names( $marcvalue, ',\s' );
		
		my $value = $plugin->marc2name( $epdata, $fieldname, $family, $given, undef);
		$epdata->{$fieldname} = $value;
	}
	# ZORA specific
	elsif ($marcvalue =~ /^IDSUx/)
	{
		$marcvalue =~ s/IDSUx//g;
		
		my $marcorganisation = $plugin->get_marc_subfield( 'b' );
		$marcorganisation = encode( 'utf-8', $marcorganisation );
		$marcorganisation =~ s/IDSUx//g;
	
		my $degreetypemap = $session->get_repository->config( 'marcdegreetypemap' );
		my $facultymap = $session->get_repository->config( 'facultymap' );
		my $collectionsmap = $session->get_repository->config( 'collectionsmap' );
		
		if (defined $degreetypemap->{$marcvalue})
		{
			$epdata->{type} = $degreetypemap->{$marcvalue};
		}
		
		if (defined $facultymap->{$marcorganisation})
		{
			$epdata->{faculty} = $facultymap->{$marcorganisation};
		}
		
		my $collections = $collectionsmap->{$marcorganisation};
		
		if (defined $collections)
		{
			foreach my $collection (@$collections)
			{
				push @{$epdata->{subjects}}, $collection;
			}
		}
	}
	
	return;
}

#
# Faculty and subjects from 909b, if possible
#
sub marc2faculty
{
	my ($plugin, $epdata, $fieldname, $marcvalue, $opt) = @_;
	
	return if ( $opt->{ind1} ne 'U');
	
	my $value;
	
	my $session = $plugin->{session};
	my $marcvalue_enc = encode( 'utf-8', $marcvalue );
	
	# read the configuration
	my $facultymap = $session->get_repository->config( 'facultymap' );
	my $collectionsmap = $session->get_repository->config( 'collectionsmap' );
	
	# Assign faculty
	my $faculty = $facultymap->{$marcvalue_enc};
	
	if ( !defined $faculty )
	{
		if ( !defined $epdata->{$fieldname} )
		{
			# this should normally not happen, but who knows if facultymap is complete?
			$epdata->{suggestions} .= "\nFaculty could not be assigned from " . $marcvalue . ". Please check fulltext.";
			$value = '';
		}
		else
		{
			$value = $epdata->{$fieldname};
		}
	}
	else
	{
		if ( defined $epdata->{$fieldname} && $epdata->{$fieldname} ne $faculty )
		{
			$epdata->{suggestions} .= "\nConflicting faculty assignments from metadata: " . $epdata->{$fieldname} . ", " . $faculty . 
			". Please check fulltext.";
			$value = '';
		}
		else
		{
			$value = $faculty;
		}
	}
	
	# Assign collection
	my $collections = $collectionsmap->{$marcvalue_enc};
	
	if (defined $collections)
	{
		foreach my $collection (@$collections)
		{
			push @{$epdata->{subjects}}, $collection;
		}
	}
	
	return $value;
}

=item $value = $plugin->marc2multiple( $epdata, $fieldname, $fieldvalue)

MARC conversion helper routine for multiple fields.

B<$epdata>: Current epdata hash.
B<$fieldname>: EPrints fieldname.
B<$fieldvalue>: Value to be stored, will be checked against possible duplicate value in epdata.

=cut

sub marc2multiple
{
	my ($plugin, $epdata, $fieldname, $fieldvalue) = @_;
	
	my $value = [];
	
	my $flag = 1;
	$value = $epdata->{$fieldname};
	
	if (defined $value)
	{
		foreach my $val (@$value)
		{
			$flag = 0 if ($val eq $fieldvalue);
		}
	}
	
	push @$value, $fieldvalue if $flag;
	
	return $value;
}

=item $value = $plugin->marc2name( $epdata, $fieldname, $family, $given, $orcid )

MARC conversion helper routine for person name fields.

B<$epdata>: Current epdata hash.
B<$fieldname>: EPrints fieldname.
B<$family>: Family name to be stored, will be checked against possible duplicate name in epdata
B<$given>: Given name to be stored, will be checked against possible duplicate name in epdata
B<$orcid>: ORCID iD (if available), will be checked against possible duplicate ORCID iD in epdata

=cut

sub marc2name
{
	my ($plugin, $epdata, $fieldname, $family, $given, $orcid) = @_;
	
	my $value = [];
	my $name_flag = 1;

	
	$value = $epdata->{$fieldname};
	
	if (defined $value)
	{
		foreach my $person (@$value)
		{
			$name_flag = 0 if ($person->{name}->{family} eq $family && $person->{name}->{given} =~ /^\Q$given/);
			$name_flag = 0 if (defined $orcid && $person->{orcid} eq $orcid);
		}
	}
	
	if ($name_flag)
	{
		push @$value, {
			name => {
				family => $family,
				given => $given,
			},
			orcid => $orcid,
		};
	}
		
	return $value;
}

=item $plugin->convert_leader( $leader, $epdata )

MARC conversion helper routine for leader field

B<$leader>: The content of the leader
B<$epdata>: Current epdata hash.

=cut

sub convert_leader
{
	my ($plugin, $leader, $epdata) = @_;
	
	my @arrleader = split( //, $leader );
	my $session = $plugin->{session};
	
	
	# 07  bibliographic level => type
	my $typemap = $session->get_repository->config( 'marcbiblevel2typemap' );
	my $biblevel = $arrleader[7];
	
	if (defined $typemap->{$biblevel} && !defined $epdata->{type})
	{
		$epdata->{type} = $typemap->{$biblevel};
	}
	
	# 17 - Encoding level (#, 1, 2, 3, 4, 5, 7, 8, u, z) => status
	my $statusmap = $session->get_repository->config( 'marcencoding2statusmap' );
	my $encodinglevel = $arrleader[17];
	
	if (defined $statusmap->{$encodinglevel})
	{
		$epdata->{status} = $statusmap->{$encodinglevel};
	}
	
	return;
}


=item $string = $plugin->clean_title( $string )

Helper method, removes << >> from a string and ending / or :

=cut

sub clean_title
{
	my ($plugin, $string) = @_;
	
	$string =~ s/<<//g;
	$string =~ s/>>//g;
	$string =~ s/\s\/\s*$//g;
	$string =~ s/\s:\s*$//g;
	
	return $string;
}

=item ($family, $given) = $plugin->get_person_names( $person_name, $separator )

Helper method, seperate $person_name into family and given name 

=cut

sub get_person_names
{
	my ($plugin, $person_name, $sep) = @_;
	
	my $family;
	my $given;
	
	# if separator is in name, use to split
	if ( $person_name =~ /$sep/ )
	{
		($family, $given) = split( /$sep/, $person_name );
	}
	else
	{
		# split at first space and do clean up later
		my $pos = index( $person_name, ' ' );
		$given = substr( $person_name, $pos+1 );
		$family = substr( $person_name, 0, $pos );
	}
	
	my ($family_clean, $given_clean) = $plugin->clean_name( $family, $given );
	
	return ($family_clean, $given_clean);
}
	

=item ($family, $given) = $plugin->clean_name( $family, $given )

Helper method, remove << >> from name and shift name parts such as van, van der ...

=cut

sub clean_name
{
	my ($plugin, $family, $given) = @_;

	# special case, mistake in (Aleph) catalog record
	$given =~ s/100\sL//g;
	
	my $family_clean = $family;
	my $given_clean = $given;
	
	# remove << >> and shift name parts
	if ( $family =~ /(.*?)\s<<(.*?)>>/ )
	{
		$family_clean = $2 . ' ' . $1;
	}
	my $shiftnameparts = $plugin->{session}->get_repository->config( 'marcshiftnameparts' );
	my $match = 0;
	
	foreach my $shiftnamepart (@$shiftnameparts)
	{
		next if $match;
		if ($given =~ /$shiftnamepart/i)
		{
			my $family_part = $2;
			$given_clean = $1;
			$family_clean = $family_part . ' ' . $family;
			$match = 1;
		}
	}
	
	# remove all . in given names
	$given_clean =~ s/\./ /g;
	$given_clean =~ s/^\s+|\s+$//g;
	
	return ($family_clean, $given_clean);
}

=item $value = $plugin->check_keywords( $epdata, $fieldname, $checkvalue )

Helper method, checks B<$checkvalue> against a comma-separated list of 
values in $epdata->{$fieldname}. Used for keywords.

=cut

sub check_keywords
{
	my ($plugin, $epdata, $fieldname, $checkvalue) = @_;
	
	$checkvalue =~ s/^\s+|\s+$//;
	my $checkvalue_ascii = unidecode($checkvalue);
	
	my $value = $epdata->{$fieldname};
	
	if (defined $value)
	{
		my @keywords = split( /,\s/, $value );
		my $duplicate = 0;
		foreach my $keyword (@keywords)
		{
			$keyword =~ s/^\s+|\s+$//;
			my $keyword_ascii = unidecode($keyword);
			$duplicate = 1 if (lc($keyword_ascii) eq lc($checkvalue_ascii));
		}
		$value .= ', ' . $checkvalue if (!$duplicate);
	}
	else
	{
		$value = $checkvalue;
	}
	
	return $value;
}

=item $value = $plugin->clean_institution( $guess )

Helper method, tries to guess the instition from a given $guess string.

=cut

sub clean_institution
{
	my ($plugin, $guess) = @_;
	
	my $value;
	
	if ( $guess =~ /Univ\.\sof\sZurich$/ || $guess =~ /Univ\.\sof\sZürich$/ || 
	     $guess =~ /Univ\.\sZürich$/ || $guess =~ /Univ\.\sZurich$/ || 
	     $guess =~ /Univ\.\sde\sZurich$/ || $guess =~ /Univ\.\sdi\sZurigo$/ )
	{
		$value = "University of Zurich";
	}
	else
	{
		$value = $guess;
		$value =~ s/Univ\.\sZürich/University of Zurich/g;
		$value =~ s/&/\//g;
	}
	
	return $value;
}

=item $value = $plugin->transform_language( $lang )

Helper method, transform MARC language value to EPrints language value

=cut

sub transform_language
{
	my ($plugin, $lang) = @_;
	
	my $value;
	
	my $session = $plugin->{session};
	my $languagemap = $session->get_repository->config( 'marclanguagemap' );
	
	if (defined $languagemap->{$lang})
	{
		$value = $languagemap->{$lang};
	}
	else
	{
		$value = $lang;
	}
	
	return $value;
}

=item $value = $plugin->apply_filter( $value, $filters )

Helper method, removes "garbage" text from $marcvalue using regex rules in $filter

=cut

sub apply_filters
{
	my ($plugin, $value, $filters) = @_;
	
	return $value if (!defined $filters);
		
	foreach my $filter (@$filters)
	{
		$filter = encode('utf-8', $filter);
		my $re = qr/$filter/i;
		$value =~ s/$re//g;
	}
	
	return $value;
}


=item $value = $plugin->get_marc( $doc, $marcfieldtype, $marcfield, $marcsubfield )

Utility method for extracting an item or multiple items from a MARC record on the fly.
Returns a scalar or an array.
B<$doc> contains the XML tree of the MARC and Adam data. 
B<>$marcfieldtype>, B<$marcfield>, B<$marcsubfield> defined the field to extract. If 
there are multiple fields that match, all are parsed and an array is returned.

=cut

sub get_marc
{
	my ($plugin, $doc, $marcfieldtype, $marcfield, $marcsubfield) = @_;
	
	my $value;
	my @values;
	
	my $xpc = XML::LibXML::XPathContext->new( $doc );
	$xpc->registerNs( "marc", "http://www.loc.gov/MARC21/slim" );
	
	my @marcrecords = $xpc->findnodes( './marc:record' );
	my $fieldxpath = './marc:' . $marcfieldtype . '[@tag="' . $marcfield . '"]';
	
	if ( $marcfieldtype eq 'datafield' )
	{
		my $subfieldxpath = './marc:subfield[@code="' . $marcsubfield . '"]';
	
		foreach my $marcrecord (@marcrecords) 
		{
			my @fieldnodes = $xpc->findnodes( $fieldxpath, $marcrecord );
		
			foreach my $fieldnode (@fieldnodes)
			{
				my $marcvalue = $xpc->findvalue( $subfieldxpath, $fieldnode );
				push @values, $marcvalue if $marcvalue ne '';
			}
		}
	}
	else
	{
		foreach my $marcrecord (@marcrecords) 
		{
			my $marcvalue = $xpc->findvalue( $fieldxpath, $marcrecord );
			push @values, $marcvalue if $marcvalue ne '';
		}
	}
	
	if (scalar @values == 1)
	{
		$value = $values[0];
		$value =~ s/^\s+|\s+$//g;
	}
	else
	{
		$value = \@values;
	}
	
	return $value;
}

=item $value = $plugin->get_marc_subfield( $marcsubfield )

Extracts an item from the current MARC field node and a given subfield B<$marcsubfield>.
The current MARC field node is passed as a plug-in parameter and set by 
$plugin->convert_input().

This utility method allows to get the value of a sibling subfield, e.g. in the case
where the value of another subfield is required for a decision.

It works both for non-repeating and repeating subfields. For the latter, a reference to
an array is returned.

=cut

sub get_marc_subfield
{
	my ($plugin, $marcsubfield) = @_;
	
	my $value;
	my @values;
	
	my $marcnode = $plugin->{param}->{currentnode};
	
	my $xpc = XML::LibXML::XPathContext->new( $marcnode );
	$xpc->registerNs( "marc", "http://www.loc.gov/MARC21/slim" );
	
	my $subfieldxpath = './marc:subfield[@code="' . $marcsubfield . '"]';
	
	my @subfieldnodes = $xpc->findnodes( $subfieldxpath, $marcnode );
	
	foreach my $subfieldnode (@subfieldnodes)
	{
		my $marcvalue = $subfieldnode->textContent();
		$marcvalue =~ s/^\s+|\s+$//g;
		push @values, $marcvalue if $marcvalue ne '';
	}
	
	if (scalar @values == 1)
	{
		$value = $values[0];
	}
	elsif (scalar @values > 1)
	{
		$value = \@values;
	}
	
	return $value;
}


=item $related_url = $plugin->create_primo_link( $alma_sys )

Utility method to create a related url as back link to the Primo Rechercheportal given a
Alma system number B<$alma_sys>.

=cut

sub create_primo_link
{
	my ($plugin, $alma_sys) = @_;

	my $related_url = [];
	my $catalog_url = 'https://swisscovery.slsp.ch/permalink/41SLSP_NETWORK/1ufb5t2/alma' . $alma_sys;
		
	push @$related_url, {
		url => $catalog_url,
		type => 'catalog',
	};
	
	return $related_url;
}

1;

=back

=head1 AUTHOR

Martin Braendle <martin.braendle@uzh.ch>, Zentrale Informatik, University of Zurich

=head1 COPYRIGHT

=for COPYRIGHT BEGIN

Copyright 2022- University of Zurich.

=for COPYRIGHT END

=for LICENSE BEGIN

This file is part of EPrints L<http://www.eprints.org/>.

EPrints is free software: you can redistribute it and/or modify it
under the terms of the GNU Lesser General Public License as published
by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

EPrints is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
License for more details.

You should have received a copy of the GNU Lesser General Public
License along with EPrints.  If not, see L<http://www.gnu.org/licenses/>.

=for LICENSE END
