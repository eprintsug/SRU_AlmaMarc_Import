=head1 NAME

EPrints::Plugin::Import::SRU

=cut

package EPrints::Plugin::Import::SRU;

use strict;
use warnings;
use utf8;

use EPrints::Plugin::Import::TextFile;
use LWP::Simple;
use XML::LibXML;
use XML::LibXML::XPathContext;
use URI;

use base 'EPrints::Plugin::Import::TextFile';


sub new
{
	my( $class, %params ) = @_;

	my $self = $class->SUPER::new( %params );

	$self->{name} = "SRU (rename ...)";
	$self->{advertise} = 1;
	$self->{visible} = "all";
	$self->{produce} = [ 'dataobj/eprint', 'list/eprint' ];
	$self->{screen} = "Import::SRU";

	return $self;
}

sub screen
{
	my( $self, %params ) = @_;

	return $self->{repository}->plugin( "Screen::Import::SRU", %params );
}

sub input_fh
{
	my ($self, %opts) = @_;
	return $self->EPrints::Plugin::Import::TextFile::input_fh( %opts );
}

sub input_text_fh
{
	my( $self, %opts ) = @_;
	
	my @ids;
	my $session = $self->{session};
	
	my $marcplugin = $self->get_repository->plugin( "Import::AlmaMarc" );
	
	my $fh = $opts{fh};
	my $query = join '', <$fh>;
	
	my $offset = $opts{offset};
	$offset++ if ($offset > 0);
	my $max = $opts{maxRecords};
	my $sortby = $opts{sortBy};
	
	my $sru_result = $self->submit_request( $query, $offset, $max, $sortby );
	
	my $empty_list = EPrints::List->new(
		session => $session,
		dataset => $opts{dataset},
		ids => []
	);
	
	if ($sru_result->{status} ne "ok")
	{
		print STDERR "SRU query failed. HTTP Status " . $sru_result->{rc} . "\n";
		$self->handler->message( "error", $self->html_phrase( "srw_connect_error",
			 status => $self->{session}->make_text( $sru_result->{rc} ),
			 query => $self->{session}->make_text( $query ),
		) );
		
		return $empty_list;
	}
	
	my $sru_doc = $self->parse_sru_response( $sru_result->{content} );
		
	my $diagnosticsNodes = $sru_doc->findnodes( '/srw:searchRetrieveResponse/srw:diagnostics' );
	if (defined $diagnosticsNodes)
	{
		foreach my $diagnosticsNode (@$diagnosticsNodes)
		{
			my $diagmessageNodes = $diagnosticsNode->findnodes( 'diag:diagnostic/diag:message' );
			foreach my $diagmessageNode (@$diagmessageNodes)
			{
				my $diagmessage = $diagmessageNode->textContent();
		
				$self->handler->message( "error", $self->html_phrase( "srw_error", 
					diag => $self->{session}->make_text( $diagmessage ),
				) );
				return $empty_list;
			}
		}
	}
	 
	my $recordCountNode = $sru_doc->findnodes( '/srw:searchRetrieveResponse/srw:numberOfRecords' );
	
	foreach my $node (@$recordCountNode)
	{ 
		$self->{total} = $node->textContent();
	}
	
	if ($self->{total} > 0)
	{
		my $sru_recordNodes = $sru_doc->findnodes( '/srw:searchRetrieveResponse/srw:records//srw:record' );
		
		foreach my $sru_recordNode (@$sru_recordNodes)
		{
			my $marc_recordNodes =  $sru_doc->findnodes( 'srw:recordData', $sru_recordNode);
			
			foreach my $marc_recordNode (@$marc_recordNodes)
			{
				my $epdata = $marcplugin->convert_input( $marc_recordNode );
				
				my $dataobj = $self->epdata_to_dataobj( $epdata, %opts );
				push @ids, $dataobj->id if (defined $dataobj);
			}
		}
		
		return EPrints::List->new(
			session => $session,
			dataset => $opts{dataset},
			ids => \@ids
		);
	}
	else
	{
		print STDERR "SRU: No records found\n";
		$self->handler->message( "warning", $self->html_phrase( "no_records_found" ) );
		return $empty_list;
	}

	print STDERR "SRU: Unhandled error\n";
	$self->handler->message( "error", $self->html_phrase( "unhandled_error",
		query => $self->{session}->make_text( $query ),
	) );
	
	return $empty_list;
}


=item $sru_data = $self->submit_request( $query )

Fetches a response from the SRU API

=cut

sub submit_request
{
	my ($self, $query, $offset, $max, $sortby) = @_;
	
	my $sru_data = {};
	$sru_data->{status} = "-1";
	
	my $url = $self->param( "baseurl" );
	
	my $query_full = $query;
	if (defined $sortby)
	{
		$query_full = $query . "+sortBy+" . $sortby;
	} 
	
	$url->query_form(
		"version" => "1.2",
		"operation" => "searchRetrieve",
		"query" => $query_full,
		"startRecord" => $offset,
		"maximumRecords" => $max,
		"recordSchema" => "marcxml",
	);
	
	# uncomment for debugging
	print STDERR "SRU Query: $url\n";
	
	my $req = HTTP::Request->new( "GET",$url );
	$req->header( "Accept" => "text/xml" );
	$req->header( "Accept-Charset" => "utf-8" );
	$req->header( "User-Agent" => "ZORA Sync; EPrints 3.3.x; www.zora.uzh.ch" );
	
	my $ua = LWP::UserAgent->new;
	my $response = $ua->request($req);
	my $rc = $response->code;
	$sru_data->{rc} = $rc;
	
	return $sru_data if (200 != $rc);
	
	$sru_data->{status} = "ok";
	$sru_data->{content} = $response->content;
		
	return $sru_data;
}

#
# Parses the SRU API response and returns an XML document.
#
sub parse_sru_response
{
	my ($self, $node) = @_;
	
	my $parser = XML::LibXML->new();
	my $doc = $parser->parse_string( $node );
	
	my $xpc = XML::LibXML::XPathContext->new( $doc );
	
	$xpc->registerNs( 'srw', 'http://www.loc.gov/zing/srw/' );
	$xpc->registerNs( 'marc', 'http://www.loc.gov/MARC21/slim' );
	$xpc->registerNs( 'xb', 'http://www.exlibris.com/repository/search/xmlbeans/' );
	$xpc->registerNs( 'diag', 'http://www.loc.gov/zing/srw/diagnostic/' );
		
	return $xpc;
}

1;

=head1 COPYRIGHT

=for COPYRIGHT BEGIN

Copyright 2000-2011 University of Southampton.
Copyright 2022 University of Zurich.

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

