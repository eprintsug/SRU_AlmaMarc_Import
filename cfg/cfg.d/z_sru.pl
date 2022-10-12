###############################################################################
#
#  SLSP SRU API and Import Plugin configuration
#  Part of ZORA-976
#
###############################################################################


#
# The base URL of the SLSP SRU API
#
$c->{plugins}->{"Import::SRU"}->{params}->{baseurl} = URI->new('https://swisscovery.slsp.ch/view/sru/41SLSP_NETWORK');

#
# The base url of the SLSP permalink
#
$c->{plugins}->{"Screen::Import::SRU"}->{params}->{permalink} = 'https://swisscovery.slsp.ch/permalink/41SLSP_NETWORK/1ufb5t2/';

$c->{plugins}->{"Screen::Import::SRU"}->{params}->{permalink_base} = 'https://swisscovery.slsp.ch/permalink/41SLSP_NETWORK/';

#
# DOI field to be used
#
$c->{plugins}->{"Import::SRU"}->{params}->{doifield} = 'doi';

#
# Query field mappings
#
$c->{plugins}->{"Screen::Import::SRU"}->{params}->{query_mapping} = {
	'AU' => 'alma.creator',
	'CN' => 'dc.contributor',
	'CO' => 'alma.country_of_publication_new',
        'DDC' => 'alma.dewey_decimal_class_number',
	'DOI' => 'alma.digital_object_identifier',
	'ID' => 'alma.mms_id',
	'ISBN' => 'alma.isbn',
	'ISSN' => 'alma.issn',
	'LA' => 'alma.language',
	'NA' => 'alma.name',
	'ORCID' => 'alma.orcid_identifier',
	'PB' => 'alma.publisher',
	'PG' => 'alma.pages',
	'PL' => 'alma.publisher_location',
	'PY' => 'alma.main_pub_date',
	'SE' => 'alma.series',
	'TI' => 'alma.title',
	'VL' => 'alma.volume',
};

#
# Order options
#
$c->{plugins}->{"Screen::Import::SRU"}->{params}->{order_options} = [
	'alma.main_pub_date/sort.descending',
	'alma.main_pub_date/sort.ascending',
	'alma.creator/sort.ascending',
	'alma.title/sort.ascending',
];

#
# Document types allowed for import
#
$c->{plugins}->{"Screen::Import::SRU"}->{params}->{allowedtypes} = {
        'article' => 1,
        'book_section' => 1,
        'conference_item' => 1,
        'monograph' => 1,
        'dissertation' => 1,
        'habilitation' => 1,
        'newspaper_article' => 1,
        'edited_scientific_work' => 1,
        'working_paper' => 1,
        'published_research_report' => 1,
        'scientific_publication_in_electronic_form' => 1,
};

$c->{plugins}->{"Screen::Import::SRU"}->{params}->{default_order} = 'alma.main_pub_date/sort.descending';

