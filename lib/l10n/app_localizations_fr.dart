import 'package:flutter/cupertino.dart';
import 'app_localizations.dart';

class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr(super.locale);

  @override
  String get appName => 'Comunifi';

  @override
  String get language => 'Langue';

  @override
  String get selectLanguage => 'Sélectionner la langue';

  @override
  String get choosePreferredLanguage => 'Choisissez votre langue préférée pour l\'application.';

  @override
  String get english => 'Anglais';

  @override
  String get french => 'Français';

  @override
  String get dutch => 'Néerlandais';

  @override
  String get german => 'Allemand';

  @override
  String get spanish => 'Espagnol';

  @override
  String get settings => 'Paramètres';

  @override
  String get profile => 'Profil';

  @override
  String get discussions => 'Discussions';

  @override
  String get members => 'Membres';

  @override
  String get cancel => 'Annuler';

  @override
  String get ok => 'OK';

  @override
  String get error => 'Erreur';

  @override
  String get continue_ => 'Continuer';

  @override
  String get delete => 'Supprimer';

  @override
  String get deleteEverything => 'Tout supprimer';

  @override
  String get linkAnotherDevice => 'Lier un autre appareil';

  @override
  String get transferAccountDescription => 'Transférez votre compte vers un autre appareil ou enregistrez un lien de récupération.';

  @override
  String get addNewDevice => 'Ajouter un nouvel appareil';

  @override
  String get saveRecoveryLink => 'Enregistrer le lien de récupération';

  @override
  String get dangerZone => 'Zone de danger';

  @override
  String get permanentActionsWarning => 'Ces actions sont permanentes et ne peuvent pas être annulées.';

  @override
  String get deleteAllAppData => 'Supprimer toutes les données de l\'application';

  @override
  String get deleteAllAppDataQuestion => 'Supprimer toutes les données de l\'application ?';

  @override
  String get deleteAllAppDataWarning => 'Cela supprimera définitivement :\n\n'
      '• Tous vos messages et groupes\n'
      '• Vos clés de chiffrement\n'
      '• Vos paramètres locaux\n'
      '• Vos données de profil Nostr\n\n'
      'Si vous n\'avez pas enregistré de lien de récupération, vous perdrez l\'accès à votre compte pour toujours.\n\n'
      'Cette action ne peut pas être annulée.';

  @override
  String get areYouAbsolutelySure => 'Êtes-vous absolument sûr ?';

  @override
  String get typeDeleteToConfirm => 'Tapez "DELETE" pour confirmer que vous souhaitez supprimer définitivement toutes vos données.';

  @override
  String failedToGenerateRecoveryLink(String error) => 'Échec de la génération du lien de récupération : $error';

  @override
  String failedToDeleteData(String error) => 'Échec de la suppression des données : $error';

  @override
  String get exploreGroups => 'Explorer les groupes';

  @override
  String get welcomeToComunifi => 'Bienvenue sur Comunifi !';

  @override
  String get welcomeDescription => 'Créez votre premier groupe ou explorez ceux qui existent pour commencer. Les groupes sont des espaces privés où vous pouvez partager des publications avec les membres.';

  @override
  String get createGroup => 'Créer un groupe';

  @override
  String get retry => 'Réessayer';

  @override
  String get writeMessage => 'Écrire un message';

  @override
  String get writeMessageEllipsis => 'Écrire un message...';

  @override
  String get searchDiscussions => 'Rechercher des discussions...';

  @override
  String get searchGroupsOnRelay => 'Rechercher des groupes sur le relais...';

  @override
  String get groupName => 'Nom du groupe';

  @override
  String get aboutOptional => 'À propos (optionnel)';

  @override
  String get editGroup => 'Modifier le groupe';

  @override
  String get save => 'Enregistrer';

  @override
  String get quotePost => 'Citer une publication';

  @override
  String get addYourComment => 'Ajoutez votre commentaire...';

  @override
  String get new_ => 'Nouveau';

  @override
  String get explore => 'Explorer';

  @override
  String get feed => 'Fil';

  @override
  String get uploading => 'Téléchargement...';

  @override
  String get tapToChange => 'Appuyer pour modifier';

  @override
  String get tapToChangePhoto => 'Appuyer pour modifier la photo';

  @override
  String get addPhotoOptional => 'Ajouter une photo (optionnel)';
}
