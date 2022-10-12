######################################################################
#
#  Screen::Import::SRU plugin - Import data via SRU
#
#  Part of https://idbugs.uzh.ch/browse/ZORA-529
#
#  Initial: 
#  2022/07/12/mb  - adapted from ISIWoK plugin
#
#  
######################################################################
#
#  Copyright 2022- University of Zurich. All Rights Reserved.
#
#  Martin Brändle
#  Zentrale Informatik
#  Universität Zürich
#  Stampfenbachstr. 73
#  CH-8006 Zürich
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



=head1 NAME

EPrints::Plugin::Screen::Import::SRU

=cut

package EPrints::Plugin::Screen::Import::SRU;

use Fcntl qw(:DEFAULT :seek);

use strict;
use warnings;
use utf8;

use URI::Escape;
use Encode qw(decode encode);

use base 'EPrints::Plugin::Screen::Import';


sub new
{
	my( $class, %params ) = @_;

	my $self = $class->SUPER::new(%params);

	$self->{actions} = [qw/ test_data import_data import_single /];

	return $self;
}

sub export_mimetype 
{
	my( $self ) = @_;
	
	return "text/html;charset=utf-8"; 
}


sub export
{
	my( $self ) = @_;

	my $item = $self->{processor}->{items}->[0];
	$self->{repository}->not_found, return if !defined $item;

	my $link = $self->{repository}->xml->create_data_element( "a",
		$item->id,
		href => $item->uri,
	);

	binmode(STDOUT, ":encoding(UTF-8)");
	print $self->{repository}->xml->to_string( $link );
	
	return;
}


sub properties_from
{
	my( $self ) = @_;

	$self->SUPER::properties_from;

	$self->{processor}->{offset} = $self->{repository}->param( "results_offset" );
	$self->{processor}->{offset} ||= 0;
	
	$self->{processor}->{maxRecords} = $self->{repository}->param( "resultspage_size" );
	$self->{processor}->{maxRecords} ||= 10;
	
	$self->{processor}->{sortBy} = $self->{repository}->param( "sortBy" );
	$self->{processor}->{sortBy} ||= 'alma.main_pub_date/sort.descending';

	$self->{processor}->{data} = $self->{repository}->param( "data" );

	$self->{processor}->{mms_id} = $self->{repository}->param( "mms_id" );

	$self->{processor}->{items} = [];
	
	return;
}

sub allow_import_single 
{ 
	my( $self ) = @_;
	
	return $self->can_be_viewed;
}

sub arguments
{
	my( $self ) = @_;

	return (
		offset => $self->{processor}->{offset},
		maxRecords => $self->{processor}->{maxRecords},
		sortBy => $self->{processor}->{sortBy},
	);
}

sub action_test_data
{
	my( $self ) = @_;
	
	$self->parse_query();
	
	my $tmpfile = File::Temp->new;
	syswrite($tmpfile, scalar(encode('UTF-8', $self->{repository}->param( "data" ))));
	sysseek($tmpfile, 0, 0);

	my $list = $self->run_import( 1, 0, $tmpfile ); # dry run with messages (only warnings/errors)
	$self->{processor}->{results} = $list;
	
	$self->{repository}->{query}->{param}->{data} = [ $self->{processor}->{saved_data} ];
	
	return;
}

sub action_import_data
{
	my( $self ) = @_;

	local $self->{i} = 0;
	
	$self->SUPER::action_import_data;
	
	return;
}

#
#  parse the user entered query and create a CQL query
#
sub parse_query
{
	my ($self) = @_;
	
	my $query_parsed;
	my $query = $self->{repository}->param( "data" );
	my $sortby =  $self->{repository}->param( "sortby" );
	$self->{processor}->{saved_data} = $query;
	
	my $permalink_baseurl = $self->param( "permalink_base" ); 
	my $query_mapping = $self->param( "query_mapping" );
	
	my $fields_found = 0;
	
	# strip leading and trailing spaces
	$query =~ s/^\s+|\s+$//g;
	
	my @operators = ( '=', '\sall\s', '==', '<', '>', '<=', '>=', '<>' ); 
	
	# identify fields	
	foreach my $query_field (keys %$query_mapping)
	{
		foreach my $op (@operators)
		{
			my $qre = $query_field . $op;
			my $re = qr/$qre/i;
			my $rep = $query_mapping->{$query_field} . $op;
		
			if ($query =~ /$re/ )
			{
				$fields_found++;
				$query =~ s/$re/qqs$rep/g;
			}
		}
	}
	# strip off the first qqs separator
	$query =~ s/^qqs//;
	
	if ($fields_found)
	{
		my @query_parts = split( /qqs/, $query );
		
		my $qpcount = 0;
		foreach my $query_part (@query_parts)
		{
			# special treatment for alma.mms_id=
			if ($query_part =~ /^alma\.mms_id/)
			{
				my $reb = qr/$permalink_baseurl/i;
				$query_part =~ s/$reb//;
				$query_part =~ s/=".*?\/?alma/="/;
			}
			
			$qpcount++;
			if ($query_part !~ /\sAND\s$|\sOR\s$/ && $query_part ne '' && $qpcount < $fields_found)
			{
				$query_part .= '" AND ';
			}
			elsif ($qpcount == $fields_found)
			{
				$query_part .= '"';
			}
			else
			{
				$query_part =~ s/\sAND\s$/" AND /;
				$query_part =~ s/\sOR\s$/" OR /;
			}
			$query_parsed .= $query_part;
		}
	}
	else
	{
		$query_parsed = 'alma.all_for_ui all "' . $query . '"';
	}
		
	$self->{repository}->{query}->{param}->{data} = [ $query_parsed ];
	print STDERR "SLSP Transform Query after: " . $self->{repository}->param( "data" ) . "\n";
	return;
}

sub epdata_to_dataobj
{
	my( $self, $epdata, %opts ) = @_;

	my $dataobj = $self->SUPER::epdata_to_dataobj( $epdata, %opts );

	push @{$self->{processor}->{items}},
		($dataobj || $opts{dataset}->make_dataobj( $epdata ));

	return $dataobj;
}

sub action_import_single
{
	my( $self ) = @_;

	my $repo = $self->{repository};
	my $xml = $repo->xml;

	my $eprint;

	my $plugin = $repo->plugin( "Import::SRU" );
	
	$plugin->set_handler(EPrints::CLIProcessor->new(
		message => sub { $self->{processor}->add_message( @_ ) },
		epdata_to_dataobj => sub {
			$eprint = $self->SUPER::epdata_to_dataobj( @_ );
		},
	) );

	{
		my $q = 'alma.mms_id="' . $self->{processor}->{mms_id} . '"';
		open(my $fh, "<", \$q);
		$plugin->input_fh(
			dataset => $repo->dataset( "inbox" ),
			fh => $fh,
			offset => 0,
			maxRecords => 1,
		);
	}

	if( !defined $eprint )
	{
		$self->{processor}->add_message( "error", $self->html_phrase( "error:not_found",
			mms_id => $self->{repository}->xml->create_text_node( $self->{processor}->{mms_id} )
			) );
		return;
	}

	my $fh = $self->{repository}->get_query->upload( "file" );
	if( defined $fh )
	{
		my $filename = $self->{repository}->param( "file" );
		$filename ||= "main.bin";
		my $filepath = $self->{repository}->query->tmpFileName( $fh );

		$repo->run_trigger( EPrints::Const::EP_TRIGGER_MEDIA_INFO,
			filename => $filename,
			filepath => $filepath,
			epdata => my $media_info = {},
		);

		$eprint->create_subdataobj( 'documents', {
			%$media_info,
			main => $filename,
			files => [{
				_content => $fh,
				filename => $filename,
				filesize => -s $fh,
				mime_type => $media_info->{mime_type},
			}],
		});
	}
	
	my $eprintid = $eprint->id;
	my $control_url = $eprint->get_control_url;
	my $edit_link = $xml->create_element( "a",
		href => $control_url,
	);
	$edit_link->appendChild( $self->html_phrase( "edit_item" ) );

	$self->{processor}->add_message( "message", $self->html_phrase( "import_completed",
		edit => $edit_link,
		inbox => $repo->plugin( "Screen::Items" )->render_action_link,
	) );

	if( !$self->wishes_to_export )
	{
		$self->{processor}->{items} = [];

		# re-run the search query
		$self->action_test_data;
	}
	
	return;
}

sub render_links
{
	my( $self ) = @_;

	my $frag = $self->SUPER::render_links;

	return $frag;
}

sub render
{
	my( $self ) = @_;

	my $repo = $self->{repository};
	my $xml = $repo->xml;
	my $xhtml = $repo->xhtml;

	my $items = $self->{processor}->{items};

	my $frag = $xml->create_document_fragment;

	$frag->appendChild( $self->html_phrase( "help" ) );

	my $form = $frag->appendChild( $self->render_form );
	$form->setAttribute( class => "slsp_input_form" );
	$form->setAttribute( id => "slsp_form" );
	
	my $div = $xml->create_element( "div", class => "slsp_search" );
	$div->appendChild( $self->_render_search_input );
	$div->appendChild( $self->render_actions ) ;
	$div->appendChild( $self->_render_action_buttons );
	
	$form->appendChild( $div );
	
	my $div_order = $xml->create_element( "div", class => "slsp_order" );
	my $order_label = $self->{session}->make_element( "label", class=>"label_tag", for=>"order" );
   	$order_label->appendChild( $self->html_phrase( "order_results" ) );
   	$order_label->appendChild( $self->{session}->make_text( ": " ) );
   	$div_order->appendChild( $order_label );	
	$div_order->appendChild( $self->_render_order_menu );
	
	$form->appendChild( $div_order ); 

	if( defined $items )
	{
		$frag->appendChild( $self->render_results( $items ) );
	}
	
	$frag->appendChild( $self->_render_form_js );

	return $frag;
}



sub render_results
{
	my( $self, $items ) = @_;

	my $repo = $self->{repository};
	my $xml = $repo->xml;
	my $xhtml = $repo->xhtml;
	
	my $allowedtypes = $self->param( "allowedtypes" );

	my $frag = $xml->create_document_fragment;

	$frag->appendChild( $xml->create_data_element( "h2",
		$self->html_phrase( "results" )
	) );

	my $offset = $self->{processor}->{offset};

	my $total = $self->{processor}->{plugin}->{total};
	$total = 1000 if $total > 1000;

	my $i = 0;
	my $list = EPrints::Plugin::Screen::Import::SRU::List->new(
		session => $repo,
		dataset => $repo->dataset( "inbox" ),
		ids => [0 .. ($total - 1)],
		items => {
			map { ($offset + $i++) => $_ } @$items
		}
	);
	
	$frag->appendChild( EPrints::Paginate->paginate_list(
		$repo, "results", $list,
		container => $xml->create_element( "table" ),
		show_per_page => [ 10, 20, 50 ],
		show_per_page_phrase => "Plugin/Screen/Import/SLSP:results_page_size",
		params => {
			$self->hidden_bits,
			data => $self->{processor}->{data},
			sortBy => $self->{processor}->{sortBy},
			_action_test_data => 1,
		},
		render_result => sub {
			my( $repo, $eprint, undef, $n ) = @_;
			
			my $xml = $repo->xml;
			
			my @dupes = $self->find_duplicates( $eprint );
			
			my $mms_id = $eprint->value( "source" );
			$mms_id =~ s/^SLSP:alma//;
			my $alma_id = "alma" . $mms_id;
			
			my $permalink_baseurl = $self->param( "permalink" );  
			
			my $cataloglink = $xml->create_element( "a",
				href => $permalink_baseurl . $alma_id, 
				target => "_blank",
			);
			
			$cataloglink->appendChild( $self->html_phrase( "slsplink" ));
			
			my $citation = $eprint->render_citation( "slsp_result",
				n => [$n, "INTEGER"],
				cataloglink => [ $cataloglink, "XHTML" ],
			);
			
			my $row = $xml->create_element( "div", class => "slsp_result_row" );
			
			my $col1 = $xml->create_element( "div", class => "slsp_result_col import" );
			my $col2 = $xml->create_element( "div", class => "slsp_result_col citation" );
			my $col3 = $xml->create_element( "div", class => "slsp_result_col file" );
			
			$col2->appendChild( $citation ); 
			
			if ( $eprint->is_set( "suggestions" ) )
			{
				my $warning_div = $xml->create_element( "div" );
				my $limit_warning = $repo->make_text( $eprint->value( "suggestions" ) );
				$warning_div->appendChild( $limit_warning );
				$col2->appendChild( $warning_div );
			}
			
			my $type = $eprint->value( "type" );
			
			if (!defined $allowedtypes->{$type})
			{
				$col2->appendChild( $self->html_phrase( "type_not_allowed" ) );
				
				$row->appendChild( $col1 );
				$row->appendChild( $col2 );
				$row->appendChild( $col3 );
			}
			elsif ( scalar @dupes == 0 )
			{
				my $frag = $xml->create_document_fragment;
				my $form = $frag->appendChild( $self->render_form );
				$form->setAttribute( class => "import_single" );
				$form->appendChild(
					$xhtml->hidden_field( data => $self->{processor}->{data} )
				);
				$form->appendChild(
					$xhtml->hidden_field( results_offset => $self->{processor}->{offset} )
				);
				
				$form->appendChild(
					$xhtml->hidden_field( mms_id => $mms_id )
				);
			
			    $col1->appendChild( $repo->render_action_buttons(
					import_single => $self->phrase( "action_import_single" ),
					_class => "slsp_import",
				) );
				
				my $label = $xml->create_element( "label",
					for => "slsp_file_upload" . $n,
					class => "slsp_file_upload btn btn-uzh-prime",
				);
				
				$label->appendChild( $self->html_phrase( "upload_label" ) ); 
				
				$col3->appendChild( $label );
				
				$col3->appendChild( $xml->create_element( "input",
					name => "file",
					id => "slsp_file_upload" . $n,
					file => undef,
					type => "file",
				) );
				
				my $script = $self->{session}->make_javascript("
					var j = jQuery.noConflict();
					j('#slsp_file_upload" . $n . "').change(function() {
						var file = this.files[0].name;
						j(this).prev('label').text(file);
					});
				");
					
				$col3->appendChild( $script );
				 
				$form->appendChild( $col1 );
				$form->appendChild( $col2 ); 
				$form->appendChild( $col3 );
				
				$row->appendChild( $frag );
			}
			else
			{
				$col2->appendChild( $self->html_phrase( "duplicates" ) );
				
				foreach my $dupe (@dupes)
				{
					$col2->appendChild( $xml->create_data_element( "a",
						$dupe->id,
						href => $dupe->get_control_url,
					) );
					$col2->appendChild( $xml->create_text_node( ", " ) ) if $dupe ne $dupes[$#dupes];
				}
				
				$row->appendChild( $col1 );
				$row->appendChild( $col2 );
				$row->appendChild( $col3 );
			}
			
			return $row;
		},
	) );
	
	$list->dispose();

	return $frag;
}

sub _render_search_input
{
	my( $self) = @_;
	
	my $session = $self->{session};
	
	my $frag = $session->make_doc_fragment;
	
	my $span = $session->make_element( "span" );
	
	my $input = $session->make_element("input", 
		type => "text",
		id => "data",
		name => "data",
		maxlength => 255,
		class => "ep_form_text slsp_input",
		value => $self->{processor}->{data},
		autofocus => "",
		required => "",
		placeholder => "\x{F002}",
	);
	
	$span->appendChild( $input );
	$frag->appendChild( $span );
	
	return $frag;
}

sub _render_action_buttons
{
	my( $self ) = @_;
	
	my $repo = $self->{repository};
	my $session = $self->{session};
	
	my $frag = $session->make_doc_fragment;
	
	my $input = $session->make_element( "input",
		type => "submit",
		value => $repo->phrase( "lib/searchexpression:action_search" ),
		name => "_action_test_data",
		class => "btn btn-uzh-prime slsp_btn",
	);
	
	$frag->appendChild( $input );
	
	return $frag;
}

sub _render_order_menu
{
	my( $self ) = @_;
	
	my $order_options = $self->param( "order_options" );
	
	my $default_order;
	if (defined $self->{repository}->param( "sortBy" ))
	{
		$default_order = $self->{repository}->param( "sortBy" );
	}
	else
	{
		$default_order = $self->param( "default_order" );
	}
	
	my %labels = ();
	foreach my $option (@$order_options)
	{
		$labels{$option} = $self->phrase( $option );
	}
	
	return $self->{session}->render_option_list(
		name => "sortBy",
        values => [ @$order_options ],
        default => $default_order,
        labels => \%labels,
        additional => { id => 'slsp_sortby' },
	);
}

sub _render_form_js
{
	my ($self) = @_;
	
	my $script = $self->{session}->make_javascript("
		var j = jQuery.noConflict();
		j(document).ready(function() {
  			j('#slsp_sortby').on('change', function() {
    			var slsp_form = j(this).closest('form');
    			slsp_form.find('input[type=submit]').click();
  			});
		});
	");
	
	return $script;
}

#
# This is modified copy from Screen::Import->run_import
# Standard messages in dryrun mode are not displayed, only warnings and errors.
#
sub run_import
{
	my( $self, $dryrun, $quiet, $tmp_file ) = @_;
	
	my $MAX_ERR_LEN = 1024;

	seek($tmp_file, 0, SEEK_SET);

	my $session = $self->{session};
	my $dataset = $self->{processor}->{dataset};
	my $user = $self->{processor}->{user};
	my $plugin = $self->{processor}->{plugin};
	my $show_stderr = $session->config(
		"plugins",
		"Screen::Import",
		"params",
		"show_stderr"
	);
	$show_stderr = $self->{show_stderr} if !defined $show_stderr;

	$self->{processor}->{count} = 0;

	$plugin->{parse_only} = $dryrun;
	$plugin->set_handler( EPrints::CLIProcessor->new(
		message => sub { !$quiet && $self->{processor}->add_message( @_ ) },
		epdata_to_dataobj => sub {
			return $self->epdata_to_dataobj(
				@_,
				parse_only => $dryrun,
			);
		},
	) );

	my $err_file;
	if( $show_stderr )
	{
		$err_file = EPrints->system->capture_stderr();
	}

	my @problems;

	my @actions;
	foreach my $action (@{$plugin->param( "actions" )})
	{
		push @actions, $action
			if scalar($session->param( "action_$action" ));
	}

	# Don't let an import plugin die() on us
	my $list = eval {
		$plugin->input_fh(
			$self->arguments,
			dataset=>$dataset,
			fh=>$tmp_file,
			user=>$user,
			filename=>$self->{processor}->{filename},
			actions=>\@actions,
			encoding=>$self->{processor}->{encoding},
		);
	};

	if( $show_stderr )
	{
		EPrints->system->restore_stderr( $err_file );
	}

	if( $@ )
	{
		if( $show_stderr )
		{
			push @problems, [
				"error",
				$session->phrase( "Plugin/Screen/Import:exception",
					plugin => $plugin->{id},
					error => $@,
				),
			];
		}
		else
		{
			$session->log( $@ );
			push @problems, [
				"error",
				$session->phrase( "Plugin/Screen/Import:exception",
					plugin => $plugin->{id},
					error => "See Apache error log file",
				),
			];
		}
	}
	elsif( !defined $list && !@{$self->{processor}->{messages}} )
	{
		push @problems, [
			"error",
			$session->phrase( "Plugin/Screen/Import:exception",
				plugin => $plugin->{id},
				error => "Plugin returned undef",
			),
		];
	}

	my $count = $self->{processor}->{count};

	if( $show_stderr )
	{
		my $err;
		sysread($err_file, $err, $MAX_ERR_LEN);
		$err =~ s/\n\n+/\n/g;

		if( length($err) )
		{
			push @problems, [
				"warning",
				$session->phrase( "Plugin/Screen/Import:warning",
					plugin => $plugin->{id},
					warning => $err,
				),
			];
		}
	}

	foreach my $problem (@problems)
	{
		my( $type, $message ) = @$problem;
		$message =~ s/^(.{$MAX_ERR_LEN}).*$/$1 .../s;
		$message =~ s/\t/        /g; # help _mktext out a bit
		$message = join "\n", EPrints::DataObj::History::_mktext( $session, $message, 0, 0, 80 );
		my $pre = $session->make_element( "pre" );
		$pre->appendChild( $session->make_text( $message ) );
		$self->{processor}->add_message( $type, $pre );
	}

	my $ok = (scalar(@problems) == 0 and $count > 0);

	return $list;
}


sub find_duplicates
{
	my( $self, $eprint ) = @_;

	my @dupes;
	my @dupe_ids;
	
	my $dataset = $self->{repository}->dataset( "eprint" );
	my @duplicate_fields = (
		"source",
		"doi",
		"isbn",
	);
	
	foreach my $duplicate_field (@duplicate_fields)
	{	
		my $field_value = $eprint->get_value( $duplicate_field );
		
		if (defined $field_value)
		{
			$dataset->search(
				filters => [
					{ meta_fields => [ $duplicate_field ], value => $field_value, match => "EX", },
				],
				limit => 5,
			)->map(sub {
				(undef, undef, my $dupe, undef) = @_;
		
				my $dupe_id = $dupe->id;
				my $eprint_status = $dupe->get_value( "eprint_status" );
				my $found = 0;
				foreach my $id (@dupe_ids)
				{
					$found = 1 if $id == $dupe_id;
				}
				if (!$found && $eprint_status ne "deletion")
				{
					push @dupes, $dupe;
					push @dupe_ids, $dupe_id;
				} 
			});
		}
	}

	return @dupes;
}


package EPrints::Plugin::Screen::Import::SRU::List;

use base 'EPrints::List';

sub get_records
{
	my( $self, $offset, $count ) = @_;

	$offset = 0 if !defined $offset;
	$count = $self->count - $offset if !defined $count;
	$count = @{$self->{ids}} if $offset + $count > @{$self->{ids}};

	my $ids = [ @{$self->{ids}}[$offset .. ($offset + $count - 1)] ];
	
	return (grep { defined $_ } map { $self->{items}->{$_} } @$ids);
}

1;

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

